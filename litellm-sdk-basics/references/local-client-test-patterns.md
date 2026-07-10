# Proxy Client Test Patterns

Use this when testing code against the local LiteLLM proxy examples or mixed endpoint modes.

## Proxy Base URL

When testing through a local proxy, use placeholders such as:

```python
base_url = "http://localhost:4000"
api_key = "test-virtual-key"
```

Do not reuse keys from operational CSVs, logs, screenshots, or prior generated reports.

## Endpoint Selection

- Chat models: `POST /chat/completions` or OpenAI SDK `client.chat.completions.create`.
- Responses-mode models: `POST /v1/responses` with `input`.
- Image-generation aliases: `POST /v1/responses` or the image endpoint supported by the configured LiteLLM version; inspect output item types.
- Transcription aliases: `POST /v1/audio/transcriptions` with multipart form-data and a small audio file.
- Embeddings: use embedding-specific APIs and do not assume chat fields exist.

## Permission Test Pattern

After adding a model to a virtual key:

1. Use that virtual key, not the admin key.
2. Send a tiny prompt such as `Say OK`.
3. Use a low `max_completion_tokens` or endpoint-equivalent cap.
4. Record status, model alias, endpoint, and error body class.
5. Avoid printing the virtual key in logs or final answers.

## Tool And Responses Caveat

A proxy custom hook may block `input[].type=custom_tool_call` for selected backend models. If a Responses API replay fails, check whether the request contains custom tool call items and whether the model supports that input type.
