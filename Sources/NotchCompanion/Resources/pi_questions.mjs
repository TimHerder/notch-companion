// Loaded only by this frontend; native Pi extensions and profile stay intact.
export default function (pi) {
  pi.registerTool({
    name: "notch_ask_user",
    label: "Ask user",
    description: "Ask the user a question in Notch Companion and wait for their answer. Use this when you need a decision or clarification. Optional choices are shown with a written-answer alternative.",
    parameters: {
      type: "object",
      properties: {
        question: { type: "string", minLength: 1 },
        choices: { type: "array", items: { type: "string", minLength: 1 }, maxItems: 16 },
      },
      required: ["question"],
      additionalProperties: false,
    },
    executionMode: "sequential",
    async execute(_id, params, signal, _update, ctx) {
      let answer;
      const choices = [...new Set(params.choices ?? [])];
      let written = "Write an answer…";
      while (choices.includes(written)) written += "…";
      if (choices.length) answer = await ctx.ui.select(params.question, [...choices, written], { signal });
      if ((!choices.length || answer === written) && !signal?.aborted) {
        answer = await ctx.ui.input(params.question, undefined, { signal });
      }
      return { content: [{ type: "text", text: answer === undefined ? "The user cancelled the question." : answer }], details: { answer: answer ?? null } };
    },
  });
}
