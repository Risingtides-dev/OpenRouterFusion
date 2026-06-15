#!/usr/bin/env node

/**
 * OpenRouterFusion Agent Engine
 * 
 * Headless agent process — communicates via JSON on stdin/stdout.
 * Uses @openrouter/agent for tool orchestration with file system access.
 * 
 * Protocol:
 *   stdin:  { "type": "chat", "messages": [...], "model": "...", "apiKey": "...", "systemPrompt": "..." }
 *   stdout: { "type": "text_delta", "content": "..." }
 *   stdout: { "type": "tool_start", "name": "...", "input": {...} }
 *   stdout: { "type": "tool_result", "name": "...", "output": "..." }
 *   stdout: { "type": "done", "text": "..." }
 *   stdout: { "type": "error", "message": "..." }
 *   stdout: { "type": "ready", "tools": [...] }  (on startup)
 */

import { callModel, tool, createInitialState, stepCountIs } from '@openrouter/agent';
import { OpenRouter } from '@openrouter/sdk';
import { z } from 'zod';
import fs from 'fs/promises';
import path from 'path';
import { execSync } from 'child_process';
import os from 'os';

// ─── Helpers ───

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

const previewDir = path.join(os.homedir(), 'tmp', 'openrtr-preview');

// ─── Tool Definitions ───

const fileWriteTool = tool({
  name: 'file_write',
  description: 'Write content to a file. Auto-creates parent directories. Use for saving HTML, code, configs, any text file.',
  inputSchema: z.object({
    path: z.string().describe('Absolute file path'),
    content: z.string().describe('Content to write'),
  }),
  execute: async ({ path: filePath, content }) => {
    await fs.mkdir(path.dirname(filePath), { recursive: true });
    await fs.writeFile(filePath, content, 'utf-8');
    return { success: true, path: filePath, bytes: Buffer.byteLength(content) };
  },
});

const fileReadTool = tool({
  name: 'file_read',
  description: 'Read a file from disk.',
  inputSchema: z.object({
    path: z.string().describe('Absolute file path'),
    offset: z.number().optional().describe('Start line (1-indexed)'),
    limit: z.number().optional().describe('Max lines to read'),
  }),
  execute: async ({ path: filePath, offset, limit }) => {
    const content = await fs.readFile(filePath, 'utf-8');
    const lines = content.split('\n');
    const start = (offset || 1) - 1;
    const sliced = limit ? lines.slice(start, start + limit) : lines.slice(start);
    return { content: sliced.join('\n'), totalLines: lines.length };
  },
});

const fileEditTool = tool({
  name: 'file_edit',
  description: 'Edit a file by replacing exact text. Surgical edits.',
  inputSchema: z.object({
    path: z.string().describe('File path'),
    oldText: z.string().describe('Exact text to find'),
    newText: z.string().describe('Replacement text'),
  }),
  execute: async ({ path: filePath, oldText, newText }) => {
    const content = await fs.readFile(filePath, 'utf-8');
    if (!content.includes(oldText)) throw new Error('oldText not found in file');
    await fs.writeFile(filePath, content.replace(oldText, newText), 'utf-8');
    return { success: true, path: filePath };
  },
});

const listDirTool = tool({
  name: 'list_dir',
  description: 'List files and directories.',
  inputSchema: z.object({
    path: z.string().describe('Directory path'),
  }),
  execute: async ({ path: dirPath }) => {
    const entries = await fs.readdir(dirPath, { withFileTypes: true });
    return entries.map(e => ({
      name: e.name,
      type: e.isDirectory() ? 'dir' : 'file',
    }));
  },
});

const shellTool = tool({
  name: 'shell',
  description: 'Execute a shell command. Returns stdout/stderr.',
  inputSchema: z.object({
    command: z.string().describe('Command to execute'),
    timeout: z.number().optional().describe('Timeout in seconds (default: 30)'),
  }),
  execute: async ({ command, timeout }) => {
    try {
      const output = execSync(command, {
        encoding: 'utf-8',
        timeout: (timeout || 30) * 1000,
        maxBuffer: 1024 * 1024,
        shell: '/bin/zsh',
      });
      return { output: output.trim() };
    } catch (err) {
      return {
        error: err.message,
        stdout: err.stdout?.toString()?.trim() || '',
        stderr: err.stderr?.toString()?.trim() || '',
      };
    }
  },
});

const previewHtmlTool = tool({
  name: 'preview_html',
  description: 'Save HTML to the preview directory. Use when the user wants to see HTML/Three.js/CSS rendered.',
  inputSchema: z.object({
    html: z.string().describe('Complete HTML content'),
    filename: z.string().optional().describe('Filename (default: preview.html)'),
  }),
  execute: async ({ html, filename }) => {
    await fs.mkdir(previewDir, { recursive: true });
    const fname = filename || 'preview.html';
    const filePath = path.join(previewDir, fname);
    await fs.writeFile(filePath, html, 'utf-8');
    return { path: filePath, url: `file://${filePath}`, bytes: Buffer.byteLength(html) };
  },
});

const allTools = [fileWriteTool, fileReadTool, fileEditTool, listDirTool, shellTool, previewHtmlTool];

// ─── Stdin JSON reader ───

let buffer = '';

process.stdin.setEncoding('utf-8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let newlineIdx;
  while ((newlineIdx = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, newlineIdx).trim();
    buffer = buffer.slice(newlineIdx + 1);
    if (!line) continue;
    try {
      handleMessage(JSON.parse(line));
    } catch (err) {
      send({ type: 'error', message: `JSON parse error: ${err.message}` });
    }
  }
});

process.stdin.on('end', () => process.exit(0));

// ─── Message handler ───

async function handleMessage(msg) {
  if (msg.type === 'ping') {
    send({ type: 'pong' });
    return;
  }

  if (msg.type === 'chat') {
    await handleChat(msg);
    return;
  }

  send({ type: 'error', message: `Unknown type: ${msg.type}` });
}

async function handleChat({ messages, model, apiKey, systemPrompt }) {
  if (!apiKey) {
    send({ type: 'error', message: 'Missing apiKey' });
    return;
  }

  const client = new OpenRouter({ apiKey });
  const targetModel = model || 'openrouter/owl-alpha';

  try {
    // Build conversation input from messages
    // The SDK accepts a string for single-turn, or an array for multi-turn
    const input = messages.map(m => ({
      role: m.role,
      content: m.content,
    }));

    const result = callModel(client, {
      model: targetModel,
      input,
      instructions: systemPrompt || 'You are a helpful coding assistant with file system access. Write complete, working code. When asked to build something, write it to disk and preview it.',
      tools: allTools,
      stopConditions: [stepCountIs(20)],
    });

    // Stream text deltas
    for await (const delta of result.getTextStream()) {
      send({ type: 'text_delta', content: delta });
    }

    // Stream tool events
    for await (const event of result.getToolStream()) {
      if (event.type === 'tool_start') {
        send({ type: 'tool_start', name: event.name, input: event.input });
      } else if (event.type === 'tool_result') {
        send({
          type: 'tool_result',
          name: event.name,
          output: typeof event.output === 'string' ? event.output : JSON.stringify(event.output),
        });
      }
    }

    const finalText = await result.getText();
    send({ type: 'done', text: finalText });

  } catch (err) {
    send({ type: 'error', message: err.message || String(err) });
  }
}

// Signal ready
send({ type: 'ready', tools: allTools.map(t => t.function?.name || t.name || 'unknown') });
