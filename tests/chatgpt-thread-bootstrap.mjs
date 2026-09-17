import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const workerSource = await fs.readFile(path.join(root, "chrome-extension", "service-worker.js"), "utf8");

const runtimeMatch = workerSource.match(/async function pageChatgptRuntimeConversationStart\(input\) \{([\s\S]*?)\n\}\n\nasync function pageChatgptConversationStart/);
assert.ok(runtimeMatch, "runtime page function must remain independently testable");
const runtimeFunctionSource = `(async function pageChatgptRuntimeConversationStart(input) {${runtimeMatch[1]}\n})`;

const verifyMatch = workerSource.match(/async function verifyChatgptPreservedRuntimeHandoff\(result, executeInTabFn, tabId\) \{([\s\S]*?)\n\}\n\nasync function pageChatgptRuntimeConversationStart/);
assert.ok(verifyMatch, "preserve-tab verification must be independently testable");
const verifyFunctionSource = `(async function verifyChatgptPreservedRuntimeHandoff(result, executeInTabFn, tabId) {${verifyMatch[1]}\n})`;

function runtimePage({
  assistantText = "bootstrap response",
  bootstrapText = "bootstrap memory",
  existingConversationId = null,
  loadedConversationId = existingConversationId,
  mountedProjectId = null,
  locationProjectId = mountedProjectId,
} = {}) {
  let submitted = null;
  const assistantNodes = existingConversationId ? [{
    innerText: "prior response",
    textContent: "prior response",
    closest: () => ({ getAttribute: () => "prior-assistant-message" }),
  }] : [];
  const location = loadedConversationId
    ? {
        origin: "https://chatgpt.com",
        pathname: locationProjectId
          ? `/g/${locationProjectId}-coding-sessions/c/${loadedConversationId}`
          : `/c/${loadedConversationId}`,
        href: `https://chatgpt.com/g/${locationProjectId}-coding-sessions/c/${loadedConversationId}`,
      }
    : {
        origin: "https://chatgpt.com",
        pathname: `/g/${locationProjectId}/project`,
        href: `https://chatgpt.com/g/${locationProjectId}/project`,
      };
  const sharedProps = {
    isComposerSubmissionReady: true,
    isDisabled: false,
    conversation: { id: "client-thread" },
    composerController: {},
    isNewThread: existingConversationId === null,
    conversationMode: mountedProjectId
      ? { kind: "gizmo_interaction", gizmo_id: mountedProjectId }
      : { kind: "primary_assistant" },
    availableSystemHints: [],
    submitComposer(event, intent) {
      submitted = { event, intent };
      if (!existingConversationId) {
        location.pathname = mountedProjectId
          ? `/g/${mountedProjectId}-coding-sessions/c/runtime-conversation`
          : "/c/runtime-conversation";
      }
      assistantNodes.push({
        innerText: assistantText,
        textContent: assistantText,
        closest: () => ({ getAttribute: () => "runtime-assistant-message" }),
      });
      return { accepted: true, completion: Promise.resolve(true) };
    },
  };
  const runtimeStore = { getSharedProps: () => sharedProps };
  const storeFiber = {
    child: null,
    sibling: null,
    return: null,
    elementType: function RuntimeStoreOwner() {},
    memoizedProps: {},
    memoizedState: { memoizedState: runtimeStore, baseState: null, next: null },
  };
  const modelFiber = {
    child: storeFiber,
    sibling: null,
    return: null,
    elementType: function ComposerModelContext() {},
    memoizedProps: {
      onCreateNewCompletion(event) {
        return typeof event.content === "string" ? event.content.length : undefined;
      },
      currentModelId: "gpt-5-6-pro",
      currentModelConfig: {},
      conversation: sharedProps.conversation,
      isNewThread: sharedProps.isNewThread,
      disabled: false,
      submitPending: false,
      isCompletionInProgress: false,
    },
    memoizedState: null,
  };
  storeFiber.return = modelFiber;
  const rootFiber = { child: modelFiber, sibling: null, return: null, elementType: function Root() {}, memoizedProps: {}, memoizedState: null };
  modelFiber.return = rootFiber;
  const composer = { "__reactFiber$test": modelFiber };
  const context = {
    Date: class extends Date { static now() { return 1_000; } },
    Event,
    Intl,
    Request,
    Response,
    TextDecoder,
    TextEncoder,
    URL,
    clearTimeout,
    console,
    crypto: crypto.webcrypto,
    document: {
      querySelector(selector) { return selector === "#prompt-textarea" ? composer : null; },
      querySelectorAll(selector) { return selector === '[data-message-author-role="assistant"]' ? assistantNodes : []; },
    },
    fetch: async () => { throw new Error("bootstrap test must not use raw fetch"); },
    getComputedStyle: () => ({ display: "block", visibility: "visible" }),
    location,
    setTimeout(callback) { queueMicrotask(callback); return 1; },
  };
  const run = vm.runInNewContext(runtimeFunctionSource, context);
  return { run, submitted: () => submitted };
}

const projectId = "g-p-6a8dee0602b0819184fa43aae5a20ee9";
const bootstrapPage = runtimePage({ mountedProjectId: projectId });
const bootstrapResult = await bootstrapPage.run({
  prompt: "normal prompt",
  bootstrapPrompt: "bootstrap memory",
  projectId,
  preserveTab: true,
});
assert.equal(bootstrapResult.ok, true);
assert.equal(bootstrapPage.submitted().intent.text, "bootstrap memory");
assert.equal(bootstrapResult.bootstrap_selected, true);
assert.equal(bootstrapResult.prompt_bytes, Buffer.byteLength("bootstrap memory", "utf8"));

const continuationPage = runtimePage({ existingConversationId: "existing-conversation", mountedProjectId: projectId });
const continuationResult = await continuationPage.run({
  prompt: "normal prompt",
  bootstrapPrompt: "bootstrap memory",
  projectId,
  preserveTab: true,
});
assert.equal(continuationResult.ok, true);
assert.equal(continuationPage.submitted().intent.text, "normal prompt");
assert.equal(continuationResult.bootstrap_selected, false);

const mismatchedPage = runtimePage({ mountedProjectId: projectId, locationProjectId: "g-p-different-project" });
const mismatchedResult = await mismatchedPage.run({
  prompt: "normal prompt",
  projectId,
  preserveTab: true,
});
assert.equal(mismatchedResult.ok, false);
assert.equal(mismatchedResult.error.code, "CHATGPT_RUNTIME_TAB_PROJECT_MISMATCH");
assert.equal(mismatchedPage.submitted(), null);

const persistedRead = async (input) => ({
  ok: true,
  conversation_id: input.conversationId,
  assistant_message_id: input.assistantMessageId,
  assistant_text: "exact mounted response",
  persisted_response_bytes: Buffer.byteLength("exact mounted response", "utf8"),
  observation_source: "persisted-conversation",
});
const executeCalls = [];
const verify = vm.runInNewContext(verifyFunctionSource, {
  Error,
  pageChatgptPersistedAssistantRead: persistedRead,
});
const preserved = await verify({
  conversation_id: "conversation-test",
  assistant_message_id: "assistant-test",
  assistant_text: "exact mounted response",
}, async (tabId, func, args, world) => {
  executeCalls.push({ tabId, func, args, world });
  return await persistedRead(args[0]);
}, 42);
assert.equal(preserved.observation_source, "mounted-conversation-preserved");
assert.equal(executeCalls.length, 1);
assert.equal(executeCalls[0].tabId, 42);
assert.equal(executeCalls[0].func, persistedRead);
const observedArgs = executeCalls[0].args;
assert.equal(observedArgs.length, 1);
assert.equal(observedArgs[0].conversationId, "conversation-test");
assert.equal(observedArgs[0].assistantMessageId, "assistant-test");
assert.equal(observedArgs[0].timeoutMs, 15_000);
assert.equal(executeCalls[0].world, "MAIN");

await assert.rejects(
  verify({
    conversation_id: "conversation-test",
    assistant_message_id: "assistant-test",
    assistant_text: "exact runtime response",
  }, async () => ({
    ok: true,
    assistant_message_id: "assistant-test",
    assistant_text: "different mounted response",
  })),
  (error) => error.code === "CHATGPT_PRESERVED_TAB_HANDOFF_MISMATCH",
);
await assert.rejects(
  verify({ conversation_id: "conversation-test", assistant_message_id: null, assistant_text: "" }, async () => {
    throw new Error("must fail before execution");
  }),
  (error) => error.code === "CHATGPT_CONVERSATION_HANDOFF_UNCERTAIN",
);

const dispatchStart = workerSource.indexOf('case "tabs.chatgptConversationStart"');
const dispatchEnd = workerSource.indexOf('case "tabs.chatgptRuntimeInventory"', dispatchStart);
const dispatchSource = workerSource.slice(dispatchStart, dispatchEnd);
const preserveVerificationStart = dispatchSource.indexOf("if (preserveTab && result?.complete === true");
const defaultVerificationStart = dispatchSource.indexOf('} else if (transport === "runtime" && result?.complete === true');
assert.ok(preserveVerificationStart >= 0, "preserve-tab completion verification is missing");
assert.ok(defaultVerificationStart > preserveVerificationStart, "default completion branch is missing");
const preserveCompletion = dispatchSource.slice(preserveVerificationStart, defaultVerificationStart);
const defaultCompletion = dispatchSource.slice(defaultVerificationStart, dispatchSource.indexOf("const settledTab", defaultVerificationStart));
assert.match(preserveCompletion, /verifyChatgptPreservedRuntimeHandoff/);
assert.doesNotMatch(preserveCompletion, /chrome\.tabs\.reload/);
assert.match(defaultCompletion, /await chrome\.tabs\.reload\(tab\.id\);/);
assert.match(defaultCompletion, /pageChatgptPersistedAssistantRead/);
assert.ok(
  defaultCompletion.indexOf("chrome.tabs.reload") < defaultCompletion.indexOf("pageChatgptPersistedAssistantRead"),
  "default verification must reload before reading the persisted response",
);

console.log("chatgpt thread bootstrap test passed");
