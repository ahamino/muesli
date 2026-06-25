import Foundation

enum ComputerUsePlannerError: LocalizedError, Equatable {
    case notAuthenticated
    case invalidResponse(String)
    case invalidToolCall(name: String, arguments: String, message: String)
    case backendFailed(statusCode: Int, message: String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Connect ChatGPT to use model-driven computer use."
        case .invalidResponse(let message):
            return "CUA planner returned an invalid tool call. \(message)"
        case .invalidToolCall(let name, let arguments, let message):
            return "CUA planner returned an invalid tool call. \(message) Raw native tool call: \(name) \(String(arguments.prefix(800)))"
        case .backendFailed(let statusCode, let message):
            return "CUA planner failed with status \(statusCode). \(message)"
        case .requestFailed(let message):
            return "CUA planner could not be reached. \(message)"
        }
    }
}

enum ComputerUsePlannerClient {
    private static let whamURL = URL(string: "https://chatgpt.com/backend-api/wham/responses")!
    static let defaultModel = "gpt-5.5"

    static var instructions: String {
        instructions(for: AppConfig())
    }

    static func instructions(for config: AppConfig) -> String {
        """
    You are Muesli's computer-use planner. You do not execute actions. You must choose exactly one native tool call from the provided tool list.

    Current app-control preference: \(config.computerUseInteractionMode.label).
    \(interactionModeInstructions(for: config.computerUseInteractionMode))

    Rules:
    - Only use element_index or element_id values present in latest_window_state. Element references expire after each new get_app_state/get_window_state or refreshed state. They are snapshot addresses, not persistent focus handles.
    - Tools have two execution contracts. Scoped tools accept target identity such as process_id, window_id, element_index/element_id, or screenshot_id and Muesli refuses the action if the live target no longer matches. Ambient tools act on current app/focus and say so in their schema; use them only after you intentionally established current focus.
    - Never invent AppleScript, shell commands, code, URLs, or tools.
    - For app launch/navigation, use launch_app with the requested app name or app bundle id. Do not substitute another app because it is frontmost, visible, or present in examples.
    - After launch_app, Muesli will refresh the requested app's state automatically. If the next state is not the requested app, call get_window_state or get_app_state for that app before using fail.
    - Use get_window_state as the canonical observe step once you have process_id/window_id for the target. Include those IDs so Muesli can keep the refreshed snapshot on the intended process/window. Use get_app_state only when the current state is insufficient, appears to be for the wrong app, or you do not yet know the target window.
    - If latest_window_state.target_mismatch is present, the requested window was not refreshed. Do not act or finish from that state; re-orient with list_windows/get_window_state for the intended or actual visible window first.
    - The screenshot is the source of truth for visual web and canvas UIs. AX candidates, focused_element, DOM text, and OCR are hints that help you choose actions, not proof that a semantic task succeeded.
    - Use recognize_screenshot_text when visible text in the latest screenshot would materially help interpret the UI. OCR is optional and model-directed; do not call it on every step by default.
    - Prefer visual pointer/keyboard primitives for rich web UIs such as YouTube, Google Docs, Google Sheets, X/Twitter, and other browser apps: click_point, move_cursor, scroll, press_key, type_text, paste_text, and hotkey. Use click_point with screenshot_id for visible video results, buttons, menus, canvas editors, and visually obvious targets.
    - Use click_element/set_value/focus_element/activate_focused mainly for native macOS controls, dialogs, menus, standard text fields, or clearly exposed AX elements. Do not tab through or AX-activate generic web areas, action menus, or ambiguous links when the visible target can be clicked by screenshot coordinate.
    - Keyboard focus is state. latest_window_state.focused_element describes the control that currently receives keyboard input. press_key is ambient: it always sends a key to current focus, accepts process_id as a focused-process guard, and never accepts window_id, element_index, or element_id.
    - Use focus_element to move focus to a specific AX candidate before press_key or text entry when that AX candidate is a reliable native/editable target. Use activate_focused when the focused_element is already the intended native button, menu item, dialog control, or explicit focused web control; avoid it for generic web areas and rich web search results.
    - Do not simulate focus by passing stale element fields to press_key. That schema is invalid. After Tab, Shift-Tab, arrow-key navigation, or a click that moves focus, use press_key directly to preserve the current focus.
    - For coordinate click/drag, use screenshot pixel coordinates from the current screenshot, not global screen coordinates.
    - Include screenshot_id from latest_window_state when using screenshot-coordinate tools.
    - latest_window_state.screenshot_ocr_text appears only after you explicitly call recognize_screenshot_text for the current screenshot_id. Treat it as imperfect visual evidence to help interpret the screenshot, not as a deterministic validation result. You still decide whether the visible UI satisfies the task.
    - Use click_point for screenshot coordinates and click_element only for reliable AX candidates. Never use legacy click unless it appears in an old prior trace.
    - For new or separate browser tasks, prefer open_new_browser_tab and then navigate_active_browser_tab. Use list_browser_tabs and activate_browser_tab only when the user asks to continue, find, or reuse an existing tab.
    - Browser DOM/page tools are optional accelerators. Use page_get_text/page_query_dom when useful, but do not depend on them as the control path.
    - If page_get_text, page_query_dom, or list_browser_tabs fails, is blocked by Chrome Apple Events JavaScript permission, returns insufficient content, or returns no tabs, immediately continue with get_window_state and visual screenshot actions. For browser pages, prefer click_point on visible targets over AX focus/activation loops; use AX only as a hint or for a clearly exposed native/editable control.
    - For text entry, prefer scoped calls: include process_id, window_id, and element_index/element_id when an editable target or web editor surface is visible in the latest state. If no element is available, type_text/paste_text act on the focused editable target and any supplied process_id/window_id must match that live focus target.
    - type_text focuses the requested element, tries AXSelectedText insertion, and falls back to targeted key events. Use it for Google Docs, browser text editors, and normal text fields.
    - paste_text uses the same target contract and may fall back to clipboard paste with restoration. Prefer it for Apple Notes and native rich-text editors when multi-word insertion by paste is likely more reliable.
    - Do not use fail only because a browser DOM/page tool failed. Use fail only after trying the available visual screenshot fallback path, or when the requested task is unsafe or truly unsupported.
    - After get_window_state/get_app_state returns a fresh state, act on the visible AX/screenshot evidence. Do not call get_app_state/get_window_state repeatedly unless a tool result indicates the app/window changed or a previous action needs verification.
    - Tool results report primitive actions such as clicked, typed, pasted, pressed, or sent activation. They do not prove the user's semantic task is complete. Inspect the next screenshot/state yourself before deciding whether to continue or finish.
    - Every mutating action result includes a post-action observation and screenshot when available. For text entry, AX may not expose canvas-backed editors such as Google Docs; if the prior outcome says AX did not expose the requested text, inspect the latest screenshot and screenshot_ocr_text yourself. If the requested text/edit is visibly present, finish. If it is not visible, choose a different target, different text primitive, keyboard navigation, or get_window_state before retrying.
    - If browser page tools are blocked, use the screenshot to click_point, type, press keys, hotkey, or scroll; do not loop on observation waiting for DOM access to appear, and do not fall into repeated AX focus/activate cycles on web content.
    - navigate_url and navigate_active_browser_tab may only use http or https URLs. Never output javascript:, file:, data:, shell text, or arbitrary code.
    - For navigate_url, include window_index/tab_index only when they came from a recent list_browser_tabs result. After open_new_browser_tab, call navigate_active_browser_tab.
    - max_steps is a high safety ceiling, not a target. Use as few steps as needed.
    - Use finish only when the user's command is complete and successful. For writing/editing tasks, finish only after you have inspected the latest AX state/screenshot and the requested text or edit is visible, or a prior outcome verified it. If the task could not be completed, is blocked, is unsafe, or needs missing permission/confirmation, use fail(reason); never put blocked or incomplete language in finish.
    - Risky actions are locally blocked by Muesli; do not try to bypass confirmation.
    """
    }

    private static func interactionModeInstructions(for mode: ComputerUseInteractionMode) -> String {
        switch mode {
        case .direct:
            return "The user allows Muesli to bring target apps forward when a tool needs direct app control."
        case .quiet:
            return "Keep the user's current app active whenever the available tools support it. Prefer process/window-scoped observation and target-scoped actions. Avoid tools marked foreground activation allowed unless the requested task has no viable quiet path, and inspect the resulting state before continuing."
        }
    }

    static func planNextTool(
        request: ComputerUsePlannerRequest,
        config: AppConfig
    ) async throws -> ComputerUsePlannerResponse {
        do {
            return try await callWHAM(
                systemPrompt: instructions(for: config),
                userPrompt: requestPrompt(for: request),
                imageDataURL: request.latestWindowState.screenshot?.imageDataURL,
                model: plannerModel(for: config)
            )
        } catch ChatGPTAuthError.notAuthenticated {
            throw ComputerUsePlannerError.notAuthenticated
        } catch let error as ComputerUsePlannerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ComputerUsePlannerError.requestFailed(error.localizedDescription)
        }
    }

    static func plannerModel(for config: AppConfig) -> String {
        let trimmed = config.computerUsePlannerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    private static func requestPrompt(for request: ComputerUsePlannerRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func callWHAM(
        systemPrompt: String,
        userPrompt: String,
        imageDataURL: String?,
        model: String
    ) async throws -> ComputerUsePlannerResponse {
        let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
        var content: [[String: Any]] = [
            ["type": "input_text", "text": userPrompt],
        ]
        if let imageDataURL {
            content.append(["type": "input_image", "image_url": imageDataURL])
        }
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": systemPrompt,
            "tools": ComputerUseToolRegistry.nativeToolDefinitions(),
            "tool_choice": "required",
            "parallel_tool_calls": false,
            "input": [
                [
                    "role": "user",
                    "content": content,
                ] as [String: Any],
            ],
        ]

        var urlRequest = URLRequest(url: whamURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !accountId.isEmpty {
            urlRequest.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard httpStatus == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let message = extractErrorMessage(from: errorData)
                ?? String(data: errorData, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpStatus)
            throw ComputerUsePlannerError.backendFailed(statusCode: httpStatus, message: String(message.prefix(800)))
        }

        var fullText = ""
        var parsedNativeToolCall: (name: String, arguments: String)?
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let outputText = json["output_text"] as? String, !outputText.isEmpty {
                fullText = outputText
            }
            if let type = json["type"] as? String, type == "response.output_text.delta",
               let delta = json["delta"] as? String {
                fullText += delta
            }
            if let toolCall = nativeToolCall(in: json) {
                parsedNativeToolCall = toolCall
            }
        }

        if let nativeToolCall = parsedNativeToolCall {
            do {
                return try ComputerUsePlannerResponse.decodeNativeToolCall(
                    name: nativeToolCall.name,
                    arguments: nativeToolCall.arguments
                )
            } catch {
                throw ComputerUsePlannerError.invalidToolCall(
                    name: nativeToolCall.name,
                    arguments: nativeToolCall.arguments,
                    message: error.localizedDescription
                )
            }
        }

        let trimmedText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        throw ComputerUsePlannerError.invalidResponse(
            trimmedText.isEmpty
                ? "The model did not return a native tool call."
                : "The model returned text instead of a native tool call: \(String(trimmedText.prefix(800)))"
        )
    }

    private static func nativeToolCall(in value: Any, depth: Int = 0) -> (name: String, arguments: String)? {
        guard depth <= 16 else { return nil }
        if let dictionary = value as? [String: Any] {
            if let type = dictionary["type"] as? String, type == "function_call",
               let name = dictionary["name"] as? String {
                return (name, argumentsString(from: dictionary["arguments"]))
            }
            if let function = dictionary["function"] as? [String: Any],
               let name = function["name"] as? String {
                return (name, argumentsString(from: function["arguments"]))
            }
            for child in dictionary.values {
                if let toolCall = nativeToolCall(in: child, depth: depth + 1) {
                    return toolCall
                }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let toolCall = nativeToolCall(in: child, depth: depth + 1) {
                    return toolCall
                }
            }
        }
        return nil
    }

    private static func argumentsString(from value: Any?) -> String {
        if let value = value as? String {
            return value
        }
        if let value,
           JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{}"
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let code = error["code"] as? String, !code.isEmpty {
                return code
            }
            return String(describing: error)
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        if let detail = json["detail"] as? String, !detail.isEmpty {
            return detail
        }
        return nil
    }
}
