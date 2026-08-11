defmodule Eva.Extension.Research do
  use Eva.Core.Extension

  @research_system_prompt """
  You are a read-only research subagent. The parent agent delegates questions to you.
  You do NOT see the parent's conversation. You do NOT talk to the user. The parent
  already streams your progress (file reads appear in its UI). Your ONLY job is to
  explore silently, then produce a single final report.

  ## TURN BUDGET — READ THIS FIRST

  You have at most 10 turns. **Each turn with a tool call (read or bash) counts.**
  You MUST reserve your final turn for writing the report.

  - Turns 1–7: read files, search with rg, trace references. Do NOT write text on
    these turns — just tool calls. Every word you write here ends up in the transcript
    and becomes noise the parent must filter out.
  - Turn 7 or 8: synthesize what you know.
  - Turn 8 or 9: write ONLY the final report. No preamble. No "Let me start by..."
    or "Good, now let me..." or "I think I have enough..." — just the report.

  A good report from 5 files is better than 32 tool calls and zero output.

  ## Process (silent — tool calls only until the final turn)

  1. Read 2–3 key files mentioned in the question or hints.
  2. Search with rg for core patterns. One or two searches, not ten.
  3. Follow one or two important references. Enough to be confident.
  4. On your penultimate turn, synthesize. On your final turn, write the report.

  ## Constraints

  - **Read-only.** Do not write, edit, or modify any file. If you need to suggest a
    change, describe it in text. The `bash` tool refuses mutating commands (`rm`, `mv`,
    output redirection, interpreters, network fetches) — don't waste turns trying.
  - **Do not reproduce source code.** Describe what the code does, not what it says.
    Cite file paths and line numbers — do not paste code blocks unless a single short
    line is essential to the answer.
  - **Stay on task.** One research question per invocation. Do not wander into
    adjacent topics.
  - **No follow-up questions.** You cannot ask the user for clarification. If the
    question is ambiguous, state your interpretation and proceed. If you genuinely
    cannot proceed, explain why in the Unknowns section.
  - **Dead end? Say so.** If after reasonable effort you cannot find an answer, report
    it clearly under Findings with confidence `low`. Do not invent or speculate.

  ## Response budget

  - **Findings:** 3–15 bullet points. One sentence each with file:line references.
  - **Answer:** 1–3 paragraphs answering the question directly.
  - **Known unknowns:** at most 3. What you could not find and why.
  - **Next steps:** at most 3. Concrete actions, not generic suggestions.
  - **No raw transcripts.** Never log what commands you ran or files you opened.

  ## Edge cases

  - **Nothing found.** Report honestly and suggest a broader scope.
  - **Too many results.** If a search returns 30+ hits, describe the pattern and read
    the most relevant few. Do not enumerate every hit.
  - **Ambiguous code.** State both interpretations and your confidence.
  - **Scope too large.** Note in Unknowns and focus on highest-signal files first.

  ## Output format

  ## Findings
  - [One-sentence finding] — `path/to/file.ex:42` (confidence: high)
  - [Another finding] — `path/to/other.ex:15-20` (confidence: medium)

  ## Answer
  [1–3 paragraphs answering the research question directly.]

  ## Known unknowns
  - [Thing you could not determine and why]

  ## Next steps
  - [Concrete action the parent agent should take, if any]
  """

  @impl true
  def setup(ctx) do
    {:ok,
     %Spec{
       tools: [research_tool(ctx)],
       guidelines: [
         "Prefer the `research` tool over chaining `read` and `bash` calls whenever " <>
           "answering a question means exploring several files."
       ]
     }}
  end

  defp research_tool(ctx) do
    %Tools.AgentTool{
      name: "research",
      description: """
      Delegate deep codebase research to a read-only subagent. Use proactively when you
      need to trace references across multiple files, understand how a subsystem works,
      find all call sites of a function, or answer questions that require reading more
      than 3 files. The subagent returns structured findings with file:line references,
      confidence levels, and a direct answer — no raw file dumps.
      """,
      prompt_snippet: "Research the codebase thoroughly (multi-file, read-only)",
      prompt_guidelines: [
        "Delegate multi-file exploration to `research` instead of chaining reads.",
        "One research question per call — be specific, mention file paths or module names.",
        "The subagent is read-only, respects a response budget, and returns structured output.",
        "Use `research` proactively when the answer needs 4+ files or cross-referencing."
      ],
      input_schema: %{
        type: "object",
        properties: %{
          question: %{
            type: "string",
            description:
              "The research question. Be specific — name modules, functions, or patterns when you know them. " <>
                "Examples: 'How does the auth middleware validate JWTs?', " <>
                "'Find all call sites of Session.start/1 and what they pass.'"
          },
          hints: %{
            type: "string",
            description:
              "Optional starting points — file paths, module names, or grep patterns to begin with. " <>
                "Example: 'Start with lib/auth.ex and search for verify_token in lib/'."
          }
        },
        required: ["question"]
      },
      executor: fn arguments, exec_ctx ->
        question = Map.fetch!(arguments, "question")
        hints = String.trim(Map.get(arguments, "hints") || "")

        prompt = build_prompt(question, hints)

        # Name the tools directly rather than filtering `coding_tools/1` — a rename
        # there would silently hand the subagent an empty toolset.
        tools = [Eva.Coding.Tools.read_tool(ctx.cwd), read_only_bash(ctx.cwd)]

        result =
          Agents.run_agent(ctx, %{
            prompt: prompt,
            system_prompt: @research_system_prompt,
            tools: tools,
            max_turns: 100,
            timeout: :timer.minutes(3),
            on_event: fn event ->
              case event do
                %Eva.Core.Agent.Events.ToolExecutionStart{tool_name: name, args: args} ->
                  detail = progress_detail(name, args)

                  Tools.report_update(exec_ctx, %Tools.AgentToolResult{
                    content: [%Messages.TextContent{text: detail}]
                  })

                _ ->
                  :ok
              end
            end
          })

        case result do
          {:ok, messages} ->
            %Tools.AgentToolResult{
              content: [%Messages.TextContent{text: format_transcript(messages)}]
            }

          {:error, :timeout} ->
            raise "Research subagent timed out after 3 minutes. Try narrowing the question or providing more specific hints."

          {:error, reason} ->
            raise "Research subagent failed: #{inspect(reason)}"
        end
      end
    }
  end

  # -- Read-only bash -----------------------------------------------------------------
  #
  # The subagent runs unsupervised and inherits none of the session's hooks, so "read-only"
  # has to be enforced here rather than asked for in the system prompt. This is a coarse
  # guard, not a sandbox: it rejects the obvious ways to mutate state (mutating commands,
  # output redirection, interpreters, network fetches) and will miss a determined attempt
  # — an `awk` program that writes to a file from inside its quoted body, for instance.

  @denied_commands ~w(
    rm rmdir mv cp install ln touch mkdir dd tee truncate shred patch
    chmod chown chgrp chflags xattr
    python python3 ruby node deno bun perl php elixir iex escript
    npm npx yarn pnpm mix make cargo go pip pip3 gem bundle
    curl wget nc ncat ssh scp sftp rsync ftp
    kill pkill killall sudo doas su
    docker kubectl systemctl launchctl brew apt apt-get
  )

  # `git` is worth keeping — most of it is read-only, and history is good research
  # material. Allow the subcommands that only read.
  @git_read_subcommands ~w(
    log show diff status blame branch tag describe shortlog grep
    rev-parse rev-list ls-files ls-tree ls-remote cat-file show-ref for-each-ref
  )

  # Wrappers that prefix a real command; the one after them is what matters.
  @command_wrappers ~w(env time command nohup nice ionice stdbuf xargs)

  defp read_only_bash(cwd) do
    bash = Eva.Coding.Tools.bash_tool(cwd)

    %{
      bash
      | executor: fn arguments, exec_ctx ->
          command = Map.get(arguments, "command") || ""

          case read_only_violation(command) do
            nil ->
              bash.executor.(arguments, exec_ctx)

            reason ->
              raise "Refused: the research subagent is read-only and #{reason}. " <>
                      "Investigate with read/rg/find instead, and describe any change you " <>
                      "want made rather than making it."
          end
        end
    }
  end

  defp read_only_violation(command) do
    # Quoted spans are blanked first so that separators and redirections inside a
    # search pattern (`rg "a > b"`) don't read as shell syntax.
    stripped =
      command
      |> String.replace(~r/'[^']*'/, " ")
      |> String.replace(~r/"(?:[^"\\]|\\.)*"/, " ")

    if String.contains?(stripped, ">") do
      "output redirection writes files"
    else
      stripped
      |> String.split(~r/\|\||&&|[;&|\n(){}`]/)
      |> Enum.find_value(&segment_violation/1)
    end
  end

  defp segment_violation(segment) do
    case base_command(String.split(segment, ~r/\s+/, trim: true)) do
      nil ->
        nil

      {command, rest} ->
        cond do
          command in @denied_commands ->
            "`#{command}` can modify the filesystem, run arbitrary code, or reach the network"

          command == "git" and git_write?(rest) ->
            "`git #{first_subcommand(rest)}` is not one of the read-only git subcommands"

          command == "sed" and Enum.any?(rest, &String.starts_with?(&1, "-i")) ->
            "`sed -i` edits files in place"

          command == "find" and Enum.any?(rest, &(&1 in ~w(-delete -exec -execdir -fprint))) ->
            "`find` with -delete or -exec can modify files"

          true ->
            nil
        end
    end
  end

  # Peels leading environment assignments, flags, and wrapper commands to reach the
  # command actually being run. Returns it basename-only, so `/bin/rm` still trips.
  defp base_command([]), do: nil

  defp base_command([word | rest]) do
    cond do
      Regex.match?(~r/^\w+=/, word) -> base_command(rest)
      String.starts_with?(word, "-") -> base_command(rest)
      word in @command_wrappers -> base_command(rest)
      true -> {Path.basename(word), rest}
    end
  end

  defp git_write?(rest) do
    case first_subcommand(rest) do
      nil -> false
      subcommand -> subcommand not in @git_read_subcommands
    end
  end

  defp first_subcommand(rest), do: Enum.find(rest, &(not String.starts_with?(&1, "-")))

  # -- Helpers --

  defp build_prompt(question, "") do
    """
    Research question:

    #{question}
    """
  end

  defp build_prompt(question, hints) do
    """
    Research question:

    #{question}

    Starting points:

    #{hints}
    """
  end

  defp progress_detail("read", %{"path" => path}) do
    "📖 #{shorten_path(path)}"
  end

  defp progress_detail("bash", %{"command" => command}) do
    "⚡ #{String.slice(command, 0, 80)}"
  end

  defp progress_detail(_name, _args), do: "..."

  defp shorten_path(path) do
    parts = Path.split(path)
    if length(parts) > 3, do: ".../" <> Enum.join(Enum.take(parts, -3), "/"), else: path
  end

  # -- Transcript extraction --------------------------------------------------------
  #
  # The subagent is instructed to be silent (tool calls only) until its final turn,
  # then produce a single report. If it narrated on earlier turns anyway, we ignore
  # that noise and only return the last text-containing assistant message.

  @max_thinking_fallback 2_000

  defp format_transcript(messages) do
    assistant_messages = Enum.filter(messages, &match?(%Messages.AssistantMessage{}, &1))

    report =
      last_text(assistant_messages) || thinking_fallback(assistant_messages) ||
        fallback_summary(messages)

    # A run that hit max_turns or errored mid-stream still comes back as {:ok, messages}
    # — the harness just appends an empty assistant message carrying the reason. Without
    # this the parent would receive whatever the subagent happened to have said before it
    # ran out of turns, presented as a finished report.
    case run_error(assistant_messages) do
      nil ->
        report

      reason ->
        "⚠️ The research run did not finish cleanly: #{reason}. Everything below is " <>
          "partial — treat it as incomplete, and re-run with a narrower question or " <>
          "more specific hints if you need the rest.\n\n" <> report
    end
  end

  defp run_error(assistant_messages) do
    case List.last(assistant_messages) do
      %Messages.AssistantMessage{stop_reason: reason, error_message: message}
      when reason in [:error, :aborted] ->
        message || "the run ended with #{reason}"

      _ ->
        nil
    end
  end

  # Walk backwards to find the last assistant message with real text content.
  defp last_text(assistant_messages) do
    Enum.find_value(Enum.reverse(assistant_messages), fn msg ->
      case String.trim(Messages.AssistantMessage.text(msg)) do
        "" -> nil
        text -> text
      end
    end)
  end

  # Raw reasoning is exactly the noise this extension exists to keep out of the parent
  # transcript, so it is a last resort: labelled for what it is, and capped.
  defp thinking_fallback(assistant_messages) do
    thinking =
      Enum.find_value(Enum.reverse(assistant_messages), fn msg ->
        case String.trim(Messages.AssistantMessage.thinking_text(msg)) do
          "" -> nil
          text -> text
        end
      end)

    if thinking do
      "(The subagent produced no report. Its raw reasoning follows as unverified notes, " <>
        "truncated.)\n\n" <> truncate(thinking, @max_thinking_fallback)
    end
  end

  defp fallback_summary(messages) do
    tool_calls =
      messages
      |> Enum.flat_map(fn
        %Messages.AssistantMessage{content: content} ->
          Enum.flat_map(content, fn
            %Messages.ToolCall{name: name} -> [name]
            _ -> []
          end)

        _ ->
          []
      end)

    tool_results =
      messages
      |> Enum.filter(&match?(%Messages.ToolResultMessage{}, &1))
      |> Enum.map_join("\n", &truncate(Messages.content_text(&1.content), 200))

    "(Subagent ran #{length(tool_calls)} tool calls but produced no text. " <>
      "Tools: #{Enum.join(Enum.uniq(tool_calls), ", ")}.\n\n" <>
      "Tool results (truncated):\n#{tool_results}"
  end

  defp truncate(text, limit) do
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> "...", else: text
  end
end
