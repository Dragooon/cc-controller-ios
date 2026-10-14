// Regenerate with: TZ=Australia/Sydney node ios/CCKit/Scripts/generate-parity.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  actionGlyph, activityLineText, buildStatusSegments, chooseSpinnerVerb,
  composeSessionState, displayText, earlierTurnCount, entryFields,
  firstMeaningfulLine, formatContextUsage, formatCountdown, formatDuration,
  formatModelName, formatSendMessage, formatTime, formatTokenCount,
  groupToolEntries, groupTurns, mergeTranscriptEntries, normalisePromptText,
  nowSubtitle, permissionCopy, promptCollapse, reconcileQueuedNote,
  resolveSendMessageTarget, sendMessageSummary, sessionActivity, sessionNavSubtitle,
  sessionStateSegment, stateLabel, subagentStateLabel, toolArgument,
  turnOutputTokens,
} from '../../../app/lib.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const fixtureRoot = path.join(root, 'CCKit/Tests/CCKitTests/Fixtures');
const outputRoot = path.join(fixtureRoot, 'parity');
fs.mkdirSync(outputRoot, { recursive: true });
for (const file of fs.readdirSync(outputRoot)) fs.unlinkSync(path.join(outputRoot, file));

const now = '2026-09-30T14:00:00.000Z';
const iso = (minutes) => new Date(Date.parse(now) + minutes * 60_000).toISOString();
const prompt = (id, text, minutes = 0, extra = {}) => ({ id, kind: 'prompt', ts: iso(minutes), text, ...extra });
const assistant = (id, text, minutes = 1, extra = {}) => ({ id, kind: 'assistant', ts: iso(minutes), text, ...extra });
const tool = (id, name, minutes = 2, extra = {}) => ({ id, kind: 'tool', ts: iso(minutes), toolUseId: id, tool: name, state: 'done', ...extra });
const session = (overrides = {}) => ({
  id: 'session-1', state: 'working', startedAt: iso(-42), idleSince: iso(-7),
  lastTool: 'Bash', lastToolInput: { command: 'npm test' }, toolRunning: true,
  usage: { model: 'claude-fable-5-1[1m]', contextTokens: 412000, contextWindow: 1000000, contextPercent: 41.2, totalInputTokens: 6000000, inputTokens: 3100000, outputTokens: 84000, cacheHitRate: 0.4666666667 },
  subagents: [{ agentId: 'agent-1', agent: 'engineer', state: 'running' }, { agentId: 'agent-2', agent: 'researcher', state: 'done' }],
  ...overrides,
});
const readJSON = (name) => JSON.parse(fs.readFileSync(path.join(fixtureRoot, name), 'utf8'));
const webTally = (entries) => {
  const counts = new Map();
  for (const entry of entries) counts.set(entry.tool ?? 'unknown', (counts.get(entry.tool ?? 'unknown') ?? 0) + 1);
  return [...counts.entries()];
};
const fixtureEntries = [
  '5-2-prompt-1.json', '5-3-assistant-1.json', '5-4-tool-and-tool-result-pairing-1.json',
  '5-5-subagent-and-subagent-result-1.json', '5-7-compaction-interrupt-and-turn-end-1.json',
  '5-8-decision-1.json', '5-9-file-1.json',
].map(readJSON);
const cases = {};
function add(functionName, name, input, output) {
  (cases[functionName] ??= []).push({ name, input, output });
}
function call(functionName, name, input, fn) { add(functionName, name, input, fn()); }

const stableEntryID = (entry) => {
  if (entry.id) return entry.id;
  if (entry.kind === 'tool' || entry.kind === 'subagent') return `${entry.kind}|${entry.toolUseId ?? ''}`;
  if (entry.kind === 'compaction') return `compaction|${entry.ts ?? ''}`;
  if (entry.kind === 'decision') return `decision|${entry.requestId ?? ''}|${entry.behavior ?? ''}`;
  if (entry.kind === 'file') return `file|${entry.name ?? ''}`;
  return `${entry.kind ?? ''}|${entry.ts ?? ''}|${entry.text ?? entry.command ?? ''}`;
};
const groupingInputs = [
  { name: 'consecutive-prompts', entries: [prompt('p1', 'first queued prompt'), prompt('p2', 'second queued prompt', 0)], working: true },
  { name: 'before-first-prompt-and-end-duration', entries: [assistant('a0', 'before', -4), prompt('p3', 'after', -3), tool('t1', 'Read', -2), { id: 'end', kind: 'turn_end', ts: iso(-1), durationMs: 3000 }], working: false },
  { name: 'live-last-turn', entries: [prompt('p4', 'live'), tool('t2', 'Bash', 1, { state: 'running' })], working: true },
  { name: 'turn-end-without-duration', entries: [prompt('p4b', 'ended'), assistant('a4b', 'reply', 1), { id: 'end2', kind: 'turn_end', ts: iso(2) }], working: false },
  { name: 'send-message', entries: [prompt('p4c', 'message'), tool('t2c', 'SendMessage', 1, { args: { to: 'agent-1', message: { text: 'Review this' } } })], working: false },
  { name: 'group-breaks', entries: [prompt('p5', 'tools'), tool('t3', 'Read', 1), tool('t4', 'Bash', 2), { id: 'sub', kind: 'subagent', ts: iso(3), toolUseId: 'task', agent: 'engineer', state: 'running' }, { id: 'result', kind: 'subagent_result', ts: iso(3.5), toolUseId: 'task', agent: 'engineer', state: 'done', result: 'done' }, tool('t5', 'Edit', 4), assistant('a5', 'reply', 5), { id: 'unknown', kind: 'future_kind', ts: iso(6), text: 'kept' }], working: false },
  { name: 'contract-fixtures', entries: fixtureEntries.filter((entry) => entry.kind), working: false },
];
const itemDescriptor = (item) => {
  if (item.kind === 'tool-group') {
    if (item.entries.length === 1 && item.entries[0].tool === 'SendMessage') return { kind: 'sendMessage', id: stableEntryID(item.entries[0]) };
    return { kind: 'tools', id: stableEntryID(item.entries[0]), count: item.entries.length, running: item.entries.some((entry) => entry.state === 'running'), tools: item.entries.map((entry) => entry.tool ?? 'unknown'), label: `Ran ${item.entries.length} tools`, tally: webTally(item.entries) };
  }
  return { kind: item.kind === 'tool' && item.tool === 'SendMessage' ? 'sendMessage' : item.kind, id: stableEntryID(item) };
};
for (const { name, entries, working } of groupingInputs) {
  const turns = groupTurns(entries, { working, now: Date.parse(now) });
  add('groupTurns', name, { entries, working, now }, turns.map((turn, index) => ({
    id: stableEntryID(turn.prompts?.[0] ?? turn.entries?.[0] ?? { kind: 'turn', ts: turn.end?.ts ?? '' }),
    prompts: (turn.prompts ?? []).map((entry) => ({ id: entry.id ?? null, kind: entry.kind, text: entry.text ?? entry.command ?? '' })),
    items: groupToolEntries(turn.entries ?? []).map(itemDescriptor),
    end: turn.end?.id ?? null,
    durationMs: turn.durationMs,
    hasBody: turn.hasBody,
    live: turn.live,
    // app/app.js:791-797 owns the web worked-footer rule.
    worked: !working && index === turns.length - 1 && turn.entries.at(-1)?.kind === 'assistant',
  })));
}

const formatCases = [
  ['actionGlyph', [['needs', 'needs_you'], ['working', 'working'], ['idle', 'idle']], (v) => actionGlyph(v)],
  ['stateLabel', [['states', 'needs_you'], ['future', 'future_state'], ['nil', null]], (v) => stateLabel(v)],
  ['subagentStateLabel', [['running', 'running'], ['done', 'done'], ['future', 'waiting']], (v) => subagentStateLabel(v)],
  ['formatModelName', [
    ['model', 'claude-fable-5-1[1m]'],
    ['provider-fable', 'global.anthropic.claude-fable-5-1'],
    ['provider-sonnet', 'claude-sonnet-5[1m]'],
    ['provider-opus', 'us.anthropic.claude-opus-4-8-v1:0'],
    ['dated-sonnet', 'claude-sonnet-5-20260101'],
    ['empty', ''],
    ['other', 'claude-opus-5-5'],
  ], (v) => formatModelName(v)],
  ['formatTime', [['sydney', now]], (v) => formatTime(v)],
  ['formatCountdown', [['zero', 0], ['fraction', 59001], ['negative', -1]], (v) => formatCountdown(v)],
  ['chooseSpinnerVerb', [['first', 0], ['middle', 0.5], ['last', 0.999999]], (v) => chooseSpinnerVerb(v)],
  ['turnOutputTokens', [['usage', [{ kind: 'assistant', usage: { outputTokens: 84000 } }, { kind: 'assistant', usage: { output_tokens: 1000 } }]], ['none', [{ kind: 'assistant', text: 'no usage' }]]], (v) => turnOutputTokens(v)],
  ['formatDuration', [['zero', 0], ['seconds', 59000], ['hour', 3600000 + 120000 + 3000]], (v) => formatDuration(v)],
  ['formatTokenCount', [['zero', 0], ['under-thousand', 999], ['thousand', 1200], ['million', 3100000], ['negative', -1500]], (v) => formatTokenCount(v)],
  ['formatContextUsage', [['percent', [{ contextPercent: 41.2 }, false]], ['expanded', [{ contextTokens: 412000, contextWindow: 1000000 }, true]]], ([usage, expanded]) => formatContextUsage(usage, expanded)],
  ['sessionStateSegment', [['working', [session(), Date.parse(now)]], ['idle', [session({ state: 'idle', toolRunning: false }), Date.parse(now)]]], ([value, time]) => sessionStateSegment(value, time)],
  ['buildStatusSegments', [['full', [session(), { now: Date.parse(now), contextExpanded: false }]], ['expanded', [session(), { now: Date.parse(now), contextExpanded: true }]]], ([value, options]) => buildStatusSegments(value, options)],
  ['sessionNavSubtitle', [['full', [session(), Date.parse(now)]], ['needs', [session({ state: 'needs_you' }), Date.parse(now)]]], ([value, time]) => sessionNavSubtitle(value, time)],
  ['resolveSendMessageTarget', [['id', ['agent-1', [{ agentId: 'agent-1', agent: 'engineer' }]]], ['name', ['reviewer', []]]], ([to, subs]) => resolveSendMessageTarget(to, subs)],
  ['sendMessageSummary', [['summary', { summary: '## Heading\nUseful result' }], ['object', { message: { text: '\nbody' } }], ['none', {}]], (v) => sendMessageSummary(v)],
  ['formatSendMessage', [['target', [{ to: 'agent-1', message: { text: 'Polish four defects' } }, [{ agentId: 'agent-1', agent: 'engineer' }]]]], ([args, subs]) => formatSendMessage(args, subs)],
  ['earlierTurnCount', [['negative', [5, 20]], ['positive', [34, 20]]], ([total, visible]) => earlierTurnCount(total, visible)],
  ['displayText', [['home', '/Users/owner/Documents/dev/cc-controller']], (v) => displayText(v)],
  ['firstMeaningfulLine', [['markdown', '# Heading\n\n**Result**\nUseful result'], ['harness', '[harness: note]\nanswer']], (v) => firstMeaningfulLine(v)],
  ['promptCollapse', [['lines', ['a'.repeat(49) + '\nb']], ['paste', ['short', { hasPaste: true }]]], ([text, options]) => promptCollapse(text, options)],
  ['normalisePromptText', [['attachments', 'Inspect\n\nAttached files:\n- /tmp/report.txt\n- C:\\tmp\\photo.png'], ['plain', 'hello']], (v) => normalisePromptText(v)],
  ['toolArgument', [['bash', ['Bash', { command: 'npm test' }]], ['path', ['Read', { file_path: '/tmp/a.txt' }]], ['edit-path', ['Edit', { path: '/tmp/a.txt' }]], ['pattern', ['Grep', { pattern: 'needle' }]], ['agent', ['Agent', { description: 'research' }]], ['url', ['WebFetch', { url: 'https://example.com' }]], ['skill', ['Skill', { skill: 'gitlab' }]], ['fallback', ['Custom', { first: 'value' }]], ['key', ['Custom', { object: { x: 1 } }]]], ([tool, args]) => toolArgument(tool, args)],
  ['activityLineText', [['tool', session()], ['agents', session({ toolRunning: false, lastTool: null })]], (v) => activityLineText(v)],
  ['sessionActivity', [
    ['needs-state', session({ state: 'needs_you' })],
    ['needs-pending', session({ state: 'idle', pending: [{ requestId: 'approval-1' }], subagents: [], shells: [] })],
    ['working-wins', session({ state: 'working', subagents: [{ state: 'running' }], shells: [{ state: 'running' }] })],
    ['background', session({ state: 'idle', subagents: [{ state: 'running' }, { state: 'running' }, { state: 'done' }], shells: [{ state: 'running' }, { state: 'stopped' }] })],
    ['idle', session({ state: 'idle', subagents: [{ state: 'done' }], shells: [{ state: 'stopped' }] })],
  ], (v) => sessionActivity(v)],
  ['nowSubtitle', [['needs', [3, 1]], ['none', [3, 0]]], ([total, needs]) => nowSubtitle(total, needs)],
  ['composeSessionState', [['working', [session(), Date.parse(now)]], ['idle', [session({ state: 'idle', toolRunning: false }), Date.parse(now)]], ['needs', [session({ state: 'needs_you' }), Date.parse(now)]]], ([value, time]) => composeSessionState(value, time)],
  ['entryFields', [['prompt', prompt('p', 'hello')], ['tool', tool('t', 'Bash', 1, { args: { command: 'npm test' }, text: 'done' })], ['decision-deny', { id: 'd', kind: 'decision', ts: now, behavior: 'deny' }], ['decision-allow', { id: 'd2', kind: 'decision', ts: now, behavior: 'allow' }], ['decision-session', { id: 'd3', kind: 'decision', ts: now, behavior: 'allow_session' }], ['decision-timeout', { id: 'd4', kind: 'decision', ts: now, behavior: 'timeout' }], ['decision-other', { id: 'd5', kind: 'decision', ts: now, behavior: 'other' }], ['file', { id: 'f', kind: 'file', name: 'out.png', size: 3, mime: 'image/png', url: '/file' }]], (v) => entryFields(v)],
  ['permissionCopy', [['bash', { tool_name: 'Bash', tool_input: { command: 'npm test', description: 'Run tests' }, agent_type: 'engineer', holdLimitMs: 590000 }], ['read', { tool_name: 'Read', tool_input: { file_path: '/tmp/a.txt' } }]], (v) => permissionCopy(v)],
  ['reconcileQueuedNote', [['prefix', [[{ text: 'hello', queued: true }], prompt('p', 'hello world')]], ['different', [[{ text: 'hello', queued: true }], prompt('p', 'goodbye')]]], ([queued, entry]) => reconcileQueuedNote(queued, entry)],
  ['mergeTranscriptEntries', [['merge', [[prompt('p', 'first', 0)], [assistant('a', 'second', 1), prompt('p', 'duplicate', 0)]]]], ([snapshot, local]) => mergeTranscriptEntries(snapshot, local)],
];
for (const [functionName, entries, fn] of formatCases) {
  for (const [name, input] of entries) {
    const output = fn(input);
    add(functionName, name, input, output);
  }
}

for (const [functionName, functionCases] of Object.entries(cases)) {
  fs.writeFileSync(path.join(outputRoot, `${functionName}.json`), JSON.stringify({ function: functionName, cases: functionCases }, null, 2) + '\n');
}
console.log(JSON.stringify(Object.fromEntries(Object.entries(cases).map(([name, values]) => [name, values.length])), null, 2));
