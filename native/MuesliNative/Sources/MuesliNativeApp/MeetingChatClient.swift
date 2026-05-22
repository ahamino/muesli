// Purpose: Multi-turn LLM chat client for in-meeting and post-meeting transcript chat
// Created: 2026-05-22

import Foundation
import MuesliCore
import os

struct MeetingChatMessage {
    enum Role: String {
        case system, user, assistant
    }
    let role: Role
    let content: String
}

enum MeetingChatError: LocalizedError {
    case backendFailed(backend: String, statusCode: Int?, message: String)
    case emptyResponse(backend: String)
    case requestFailed(backend: String, underlying: Error)
    case notConfigured(backend: String)

    var errorDescription: String? {
        switch self {
        case let .backendFailed(backend, statusCode, message):
            let statusText = statusCode.map { " Status \($0)." } ?? ""
            return "\(backend) could not respond.\(statusText) \(message)"
        case let .emptyResponse(backend):
            return "\(backend) returned an empty response."
        case let .requestFailed(backend, underlying):
            return "\(backend) could not be reached. \(underlying.localizedDescription)"
        case let .notConfigured(backend):
            return "\(backend) is not configured. Please add an API key in Settings."
        }
    }
}

enum MeetingChatClient {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingChat")
    private static let openAIURL = URL(string: "https://api.openai.com/v1/responses")!
    private static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let whamURL = URL(string: "https://chatgpt.com/backend-api/wham/responses")!
    private static let defaultOllamaBaseURL = URL(string: "http://localhost:11434")!
    private static let defaultOpenAIModel = "gpt-5.4-mini"
    private static let defaultOpenRouterModel = "stepfun/step-3.5-flash:free"
    private static let defaultChatGPTModel = "gpt-5.4-mini"
    private static let defaultOllamaModel = "qwen3.5"
    private static let chatTimeout: TimeInterval = 120
    // ~90k token budget; rough char estimate at 4 chars/token
    private static let maxTranscriptChars = 360_000

    static func send(messages: [MeetingChatMessage], config: AppConfig) async throws -> String {
        let backend = (config.meetingSummaryBackend.isEmpty
            ? MeetingSummaryBackendOption.chatGPT.backend
            : config.meetingSummaryBackend).lowercased()

        if backend == MeetingSummaryBackendOption.chatGPT.backend {
            return try await sendWithChatGPT(messages: messages, config: config)
        }
        if backend == MeetingSummaryBackendOption.openRouter.backend {
            return try await sendWithOpenRouter(messages: messages, config: config)
        }
        if backend == MeetingSummaryBackendOption.ollama.backend {
            return try await sendWithOllama(messages: messages, config: config)
        }
        return try await sendWithOpenAI(messages: messages, config: config)
    }

    // MARK: - Context window

    /// Returns a copy of messages with the system prompt's transcript trimmed to fit the budget.
    static func trimmedMessages(_ messages: [MeetingChatMessage]) -> [MeetingChatMessage] {
        guard let sysIdx = messages.firstIndex(where: { $0.role == .system }) else {
            return messages
        }
        let sysMsg = messages[sysIdx]
        guard sysMsg.content.count > maxTranscriptChars else { return messages }

        // Keep the newest chunks — trim from the top after any header text before the transcript.
        let trimmedContent: String
        if let range = sysMsg.content.range(of: "\n---\n") {
            let header = String(sysMsg.content[..<range.upperBound])
            let body = String(sysMsg.content[range.upperBound...])
            let allowedBodyChars = maxTranscriptChars - header.count
            if allowedBodyChars > 0 {
                let trimmedBody = String(body.suffix(allowedBodyChars))
                // Drop the first (likely partial) line
                let firstNewline = trimmedBody.firstIndex(of: "\n") ?? trimmedBody.startIndex
                trimmedContent = header + "[...earlier transcript trimmed...]\n" + String(trimmedBody[firstNewline...])
            } else {
                trimmedContent = header + "[transcript omitted — too long]"
            }
        } else {
            trimmedContent = String(sysMsg.content.suffix(maxTranscriptChars))
        }

        var result = messages
        result[sysIdx] = MeetingChatMessage(role: .system, content: trimmedContent)
        return result
    }

    // MARK: - Backends

    private static func sendWithOpenAI(messages: [MeetingChatMessage], config: AppConfig) async throws -> String {
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? config.openAIAPIKey
        guard !apiKey.isEmpty else { throw MeetingChatError.notConfigured(backend: "OpenAI") }

        let trimmed = trimmedMessages(messages)
        let input: [[String: Any]] = trimmed.map { ["role": $0.role.rawValue, "content": $0.content] }
        let body: [String: Any] = [
            "model": config.openAIModel.isEmpty ? defaultOpenAIModel : config.openAIModel,
            "input": input,
            "reasoning": ["effort": "low"],
            "text": ["verbosity": "low"],
        ]

        var request = URLRequest(url: openAIURL)
        request.timeoutInterval = chatTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: "OpenAI")
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = extractOpenAIText(from: json),
                !text.isEmpty
            else {
                if let msg = extractErrorMessage(from: data) {
                    throw MeetingChatError.backendFailed(backend: "OpenAI", statusCode: nil, message: msg)
                }
                throw MeetingChatError.emptyResponse(backend: "OpenAI")
            }
            return text
        } catch {
            throw chatRequestError(backend: "OpenAI", error: error)
        }
    }

    private static func sendWithOpenRouter(messages: [MeetingChatMessage], config: AppConfig) async throws -> String {
        let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? config.openRouterAPIKey
        guard !apiKey.isEmpty else { throw MeetingChatError.notConfigured(backend: "OpenRouter") }

        let trimmed = trimmedMessages(messages)
        let model = config.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultOpenRouterModel : config.openRouterModel
        let chatMessages: [[String: Any]] = trimmed.map { ["role": $0.role.rawValue, "content": $0.content] }
        let body: [String: Any] = [
            "model": model,
            "messages": chatMessages,
        ]

        var request = URLRequest(url: openRouterURL)
        request.timeoutInterval = chatTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(AppIdentity.displayName, forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: "OpenRouter")
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = extractOpenRouterText(from: json),
                !text.isEmpty
            else {
                if let msg = extractErrorMessage(from: data) {
                    throw MeetingChatError.backendFailed(backend: "OpenRouter", statusCode: nil, message: msg)
                }
                throw MeetingChatError.emptyResponse(backend: "OpenRouter")
            }
            return text
        } catch {
            throw chatRequestError(backend: "OpenRouter", error: error)
        }
    }

    private static func sendWithOllama(messages: [MeetingChatMessage], config: AppConfig) async throws -> String {
        let baseURLString = config.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = baseURLString.isEmpty ? defaultOllamaBaseURL : (URL(string: baseURLString) ?? defaultOllamaBaseURL)
        let chatURL = baseURL.appendingPathComponent("api/chat")

        let trimmed = trimmedMessages(messages)
        let model = config.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultOllamaModel : config.ollamaModel
        let chatMessages: [[String: Any]] = trimmed.map { ["role": $0.role.rawValue, "content": $0.content] }
        let body: [String: Any] = [
            "model": model,
            "messages": chatMessages,
            "stream": false,
        ]

        var request = URLRequest(url: chatURL)
        request.timeoutInterval = chatTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: "Ollama")
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = json["message"] as? [String: Any],
                let text = message["content"] as? String,
                !text.isEmpty
            else {
                if let msg = extractErrorMessage(from: data) {
                    throw MeetingChatError.backendFailed(backend: "Ollama", statusCode: nil, message: msg)
                }
                throw MeetingChatError.emptyResponse(backend: "Ollama")
            }
            return text
        } catch {
            throw chatRequestError(backend: "Ollama", error: error)
        }
    }

    private static func sendWithChatGPT(messages: [MeetingChatMessage], config: AppConfig) async throws -> String {
        let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
        let trimmed = trimmedMessages(messages)

        let systemContent = trimmed.first(where: { $0.role == .system })?.content ?? ""
        let nonSystemMessages = trimmed.filter { $0.role != .system }
        let inputMessages: [[String: Any]] = nonSystemMessages.map { msg in
            [
                "role": msg.role == .user ? "user" : "assistant",
                "content": [["type": "input_text", "text": msg.content] as [String: Any]],
            ] as [String: Any]
        }

        let body: [String: Any] = [
            "model": config.chatGPTModel.isEmpty ? defaultChatGPTModel : config.chatGPTModel,
            "store": false,
            "stream": true,
            "instructions": systemContent,
            "input": inputMessages,
        ]

        var request = URLRequest(url: whamURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard httpStatus == 200 else {
                var errorData = Data()
                for try await byte in bytes { errorData.append(byte) }
                let msg = extractErrorMessage(from: errorData) ?? String(data: errorData, encoding: .utf8) ?? "(unknown)"
                throw MeetingChatError.backendFailed(backend: "ChatGPT", statusCode: httpStatus, message: msg)
            }

            var fullText = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = String(line.dropFirst(6))
                if jsonStr == "[DONE]" { break }
                guard let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let outputText = json["output_text"] as? String, !outputText.isEmpty {
                    fullText = outputText
                }
                if let type = json["type"] as? String, type == "response.output_text.delta",
                   let delta = json["delta"] as? String {
                    fullText += delta
                }
            }

            let result = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else { throw MeetingChatError.emptyResponse(backend: "ChatGPT") }
            return result
        } catch {
            throw chatRequestError(backend: "ChatGPT", error: error)
        }
    }

    // MARK: - Helpers

    private static func validateHTTPResponse(_ response: URLResponse, data: Data, backend: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = extractErrorMessage(from: data)
                ?? String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw MeetingChatError.backendFailed(backend: backend, statusCode: http.statusCode, message: String(message.prefix(800)))
        }
    }

    private static func chatRequestError(backend: String, error: Error) -> Error {
        error is MeetingChatError ? error : MeetingChatError.requestFailed(backend: backend, underlying: error)
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty { return message }
            if let code = error["code"] as? String, !code.isEmpty { return code }
        }
        if let message = json["message"] as? String, !message.isEmpty { return message }
        if let detail = json["detail"] as? String, !detail.isEmpty { return detail }
        return nil
    }

    private static func extractOpenAIText(from payload: [String: Any]) -> String? {
        if let text = payload["output_text"] as? String, !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for item in (payload["output"] as? [[String: Any]] ?? []) where (item["type"] as? String) == "message" {
            for entry in (item["content"] as? [[String: Any]] ?? []) {
                if let text = entry["text"] as? String, !text.isEmpty {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private static func extractOpenRouterText(from payload: [String: Any]) -> String? {
        guard let message = (payload["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { return nil }
        if let content = message["content"] as? String, !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
