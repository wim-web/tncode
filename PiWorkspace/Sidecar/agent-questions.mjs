import { randomUUID } from "node:crypto";

const maxAnswerLength = 4000;
const text = (maxLength) => ({ type: "string", minLength: 1, maxLength });
const optionSchema = {
  type: "object",
  properties: { label: text(160), description: text(500) },
  required: ["label"],
  additionalProperties: false,
};
const questionSchema = {
  type: "object",
  properties: {
    header: text(120),
    prompt: text(4000),
    options: { type: "array", items: optionSchema, maxItems: 9 },
    multiSelect: { type: "boolean" },
  },
  required: ["header", "prompt"],
  additionalProperties: false,
};

function answerQuestions(questions, reply, redact) {
  if (!Array.isArray(reply) || reply.length !== questions.length) return;
  const answers = [];
  for (const [index, question] of questions.entries()) {
    const answer = reply[index];
    if (answer?.questionID !== question.id) return;
    if (answer.kind === "text" && typeof answer.text === "string") {
      const value = answer.text.trim();
      if (!value || value.length > maxAnswerLength || redact(value) !== value) return;
      answers.push({ questionID: question.id, text: value });
    } else if (answer.kind === "options" && Array.isArray(answer.selected)) {
      const selected = new Set(answer.selected);
      if (!selected.size || selected.size !== answer.selected.length ||
          (!question.multiSelect && selected.size !== 1) ||
          !answer.selected.every((index) => Number.isInteger(index) && index >= 0 && index < question.options.length)) return;
      answers.push({
        questionID: question.id,
        selected: question.options.filter((_, index) => selected.has(index)).map(({ label }) => label),
      });
    } else {
      return;
    }
  }
  return answers;
}

export function createAgentQuestions({ threadID, currentTurn, emit, redact, stopTurn, timeout = 300_000 }) {
  let pending;

  function settle(status, answers) {
    const request = pending;
    if (!request) return;
    pending = undefined;
    clearTimeout(request.timer);
    request.resolve({ status, answers });
    emit({ type: "agentQuestionEnded", scope: request.scope, status });
  }

  function expire(scope) {
    if (pending?.scope !== scope) return;
    settle("expired");
    if (currentTurn() === scope.turnID) stopTurn();
  }

  return {
    tool: {
      name: "ask_user_questions",
      label: "Ask user questions",
      description: "Ask the user one or more questions when their input is needed. Call this tool on its own. " +
        "Include optional choices when helpful. The user can also type answers or dismiss the request. " +
        "Never ask for passwords, API keys, or tool approval.",
      parameters: {
        type: "object",
        properties: { questions: { type: "array", items: questionSchema, minItems: 1, maxItems: 12 } },
        required: ["questions"],
        additionalProperties: false,
      },
      executionMode: "sequential",
      async execute(_toolCallID, args, signal) {
        const turnID = currentTurn();
        let result = { status: "cancelled" };
        if (turnID && !signal?.aborted && !pending) {
          const questions = args.questions.map((question, index) => ({
            id: String(index + 1),
            header: redact(question.header),
            prompt: redact(question.prompt),
            options: (question.options ?? []).map(({ label, description }) => ({
              label: redact(label), description: redact(description),
            })),
            multiSelect: question.multiSelect === true,
          }));
          const scope = { threadID, turnID, requestID: randomUUID().toUpperCase() };
          const abort = () => {
            if (pending?.scope === scope) settle("cancelled");
          };
          result = await new Promise((resolve) => {
            const deadline = performance.now() + timeout;
            const timer = setTimeout(() => expire(scope), timeout);
            pending = { scope, questions, resolve, deadline, timer };
            signal?.addEventListener("abort", abort, { once: true });
            emit({ type: "agentQuestion", scope, questions });
          }).finally(() => signal?.removeEventListener("abort", abort));
        }
        if (currentTurn() !== turnID || signal?.aborted) result = { status: "cancelled" };
        return { content: [{ type: "text", text: JSON.stringify(result) }] };
      },
    },

    respond({ scope, decision, answers }) {
      const request = pending;
      if (!request || scope?.requestID !== request.scope.requestID || scope.threadID !== threadID ||
          scope.turnID !== request.scope.turnID || currentTurn() !== scope.turnID) return;
      if (performance.now() >= request.deadline) {
        expire(request.scope);
        return;
      }
      if (decision === "decline") {
        settle("declined");
        return;
      }
      const validated = decision === "answer" && answerQuestions(request.questions, answers, redact);
      if (validated) settle("answered", validated);
      else emit({ type: "agentQuestionRejected", scope: request.scope });
    },

    cancel() { settle("cancelled"); },
  };
}
