// Internal bounded stdin decoder. Never return message content or identifiers.
import { readFileSync } from 'node:fs';
import { zstdDecompressSync } from 'node:zlib';

try {
  const limit = 1024 * 1024;
  const expected = Number(process.argv[2]);
  if (!Number.isInteger(expected) || expected <= 0 || expected > limit) throw new Error();
  const compressed = readFileSync(0);
  if (compressed.length > limit) throw new Error();
  const bytes = zstdDecompressSync(compressed, { maxOutputLength: limit });
  if (bytes.length !== expected) throw new Error();
  const event = JSON.parse(bytes.toString('utf8'));
  if (!event || typeof event !== 'object' || typeof event.type !== 'string') throw new Error();
  if (event.type === 'message' && !['user','assistant','system','developer','tool','toolResult','function'].includes(event.message?.role)) throw new Error();
  const stamp = event.timestamp;
  const eventTimestamp = typeof stamp === 'string' && /^\d{4}-\d{2}-\d{2}T[0-9:.+-]+Z?$/.test(stamp) && Number.isFinite(Date.parse(stamp)) ? stamp :
    typeof stamp === 'number' && Number.isFinite(stamp) && stamp >= 946684800000 && stamp <= 4102444800000 ? stamp : null;
  const result = {decoded:true,isMessage:event.type==='message',isUser:event.type==='message'&&event.message.role==='user',eventTimestamp};
  if (process.argv[3] === '--intent-hints') {
    const blocks = Array.isArray(event.message?.content) ? event.message.content : [];
    const text = typeof event.message?.content === 'string' ? event.message.content : blocks.filter(b=>b?.type==='text'&&typeof b.text==='string').map(b=>b.text).join('\n');
    // Hints are not authentication, an instruction, approval or task execution.
    result.intentHints = {
      modelOrIdentityMention: /模型|你是谁|什么版本/.test(text),
      reviewMention: /PPT|评审|改稿|第[一二三四五六七八九十0-9]+[页段]/i.test(text),
      fieldMention: /现场|证据|报告|照片|R[1-9][0-9]*/.test(text),
      stopMention: /停止|暂停|先停|不要继续|不用继续/.test(text),
      approvalMention: /同意\s+[a-fA-F0-9]{8}/.test(text),
      mediaAttachmentReference: /^MEDIA:/m.test(text),
      toolCallPresent: blocks.some(b=>b?.type==='toolCall'||b?.type==='tool_use')
    };
  }
  process.stdout.write(JSON.stringify(result));
} catch {
  // Do not echo parse errors, input bytes, paths, IDs or payload snippets.
  process.stdout.write(JSON.stringify({decoded:false}));
  process.exitCode = 2;
}
