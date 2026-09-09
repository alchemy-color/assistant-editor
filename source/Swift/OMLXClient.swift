import Foundation

/// Thin OpenAI-compatible client for the local oMLX inference server
/// (http://localhost:8000). Replaces the former Ollama `/api/generate` path.
/// oMLX caches models across requests (tiered KV cache), so no keep_alive
/// flag is needed — dials like `think`/`num_ctx` have no oMLX equivalent
/// and are deliberately dropped.
final class OMLXClient {

    static let shared = OMLXClient()

    static let defaultBaseURL = "http://localhost:8000"
    static let defaultModel = "Llama-3.1-8B-Instruct-4bit"

    struct Configuration {
        var baseURL: String
        var apiKey: String
        var model: String
    }

    private init() {}

    /// Current settings pulled from UserDefaults so any view can read/write them.
    var config: Configuration {
        let ud = UserDefaults.standard
        return Configuration(
            baseURL: ud.string(forKey: "omlxBaseURL") ?? OMLXClient.defaultBaseURL,
            apiKey: ud.string(forKey: "omlxAPIKey") ?? "",
            model: ud.string(forKey: "selectedModel") ?? OMLXClient.defaultModel
        )
    }

    struct ServerResult {
        var running: Bool
        var models: [String]
        var error: String?
    }

    /// Query `/v1/models`. A 401 means the server is up but the API key is
    /// wrong — that still counts as "server reachable" so the UI can prompt
    /// for a key rather than treating it as unavailable.
    func checkServer(timeout: TimeInterval = 8, _ completion: @escaping (ServerResult) -> Void) {
        var req = URLRequest(url: URL(string: "\(config.baseURL)/v1/models")!)
        req.timeoutInterval = timeout
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: req) { data, _, error in
            guard let data = data, error == nil else {
                completion(ServerResult(running: false, models: [], error: error?.localizedDescription))
                return
            }
            var models: [String] = []
            var authError = false
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = json["data"] as? [[String: Any]] {
                for m in arr {
                    if let id = m["id"] as? String { models.append(id) }
                }
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let err = json["error"] as? [String: Any],
                      (err["code"] as? String) == "401" {
                authError = true
            }
            completion(ServerResult(
                running: true,
                models: models,
                error: authError ? "Invalid API key" : nil
            ))
        }.resume()
    }

    struct CompletionResult {
        var text: String?
        var tps: Double?
        var usage: (prompt: Int, completion: Int)?
        var error: String?
    }

    /// Single non-streaming chat completion. `jsonSchema` (an NSDictionary
    /// mirroring a JSON Schema) is passed through as an OpenAI `response_format`
    /// json_schema when present, else left to the model's default mode.
    func complete(
        system: String? = nil,
        prompt: String,
        temperature: Double = 0.3,
        maxTokens: Int = 4096,
        jsonSchema: [String: Any]? = nil,
        timeout: TimeInterval = 600,
        _ completion: @escaping (CompletionResult) -> Void
    ) {
        let cfg = config
        var messages: [[String: String]] = []
        if let system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        var body: [String: Any] = [
            "model": cfg.model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false
        ]
        if let jsonSchema {
            // OpenAI json_schema mode: full JSON Schema with a name.
            let name = (jsonSchema["name"] as? String)
                ?? ((jsonSchema["title"] as? String) ?? "output")
            var schema = jsonSchema
            schema.removeValue(forKey: "name")
            schema.removeValue(forKey: "title")
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": name,
                    "strict": false,
                    "schema": schema
                ]
            ]
        }

        var req = URLRequest(url: URL(string: "\(cfg.baseURL)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.apiKey.isEmpty {
            req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, _, error in
            guard let data = data, error == nil else {
                completion(CompletionResult(error: error?.localizedDescription ?? "No response from oMLX"))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let msg = first["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                let raw = String(data: data, encoding: .utf8) ?? "empty"
                completion(CompletionResult(error: "oMLX error: \(raw)"))
                return
            }
            var tps: Double?
            var usage: (Int, Int)?
            if let u = json["usage"] as? [String: Any] {
                let comp = (u["completion_tokens"] as? Int) ?? 0
                let prompt = (u["prompt_tokens"] as? Int) ?? 0
                usage = (prompt, comp)
                if comp > 0 {
                    // oMLX reports total_time seconds in its own usage telemetry
                    // mirror; derive tok/s from real timing when available.
                    if let tt = u["total_time"] as? Double, tt > 0 {
                        tps = Double(comp) / tt
                    }
                }
            }
            // Metre for the bottom-bar tok/s readout.
            if let u = json["usage"] as? [String: Any],
               let comp = u["completion_tokens"] as? Int, comp > 0 {
                LLMPerf.shared.recordOmlx(completionTokens: comp, timeSeconds: tps != nil ? (Double(comp) / tps!) : nil)
            }
            completion(CompletionResult(text: content, tps: tps, usage: usage))
        }.resume()
    }
}
