from __future__ import annotations

import asyncio
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch


SHIM_ROOT = Path(__file__).resolve().parents[1]
if str(SHIM_ROOT) not in sys.path:
    sys.path.insert(0, str(SHIM_ROOT))

from codex_shim.copilot_passthrough import (  # noqa: E402
    CodexRequestIdentity,
    CopilotBridge,
    _BridgeSession,
    _CachedRound,
    _PendingTool,
    _reasoning_effort,
    codex_request_identity,
    copilot_spawn_env,
    copilot_tool_declarations,
    copilot_transcript,
)
from codex_shim.server import ResponsesStreamState  # noqa: E402
from codex_shim import copilot_passthrough as copilot_module  # noqa: E402
from codex_shim import server as server_module  # noqa: E402
from codex_shim import settings as settings_module  # noqa: E402


class CopilotRequestConversionTests(unittest.TestCase):
    def test_spawn_environment_uses_login_without_auth_or_endpoint_overrides(self) -> None:
        override_keys = {
            "COPILOT_API_URL",
            "COPILOT_GITHUB_TOKEN",
            "COPILOT_SDK_AUTH_TOKEN",
            "GH_TOKEN",
            "GITHUB_COPILOT_API_TOKEN",
            "GITHUB_TOKEN",
        }
        with patch.dict(
            copilot_module.os.environ,
            {key: "must-not-leak" for key in override_keys},
            clear=False,
        ):
            environment = copilot_spawn_env()

        self.assertTrue(override_keys.isdisjoint(environment))
        self.assertEqual(environment["COPILOT_SKIP_CLI_DOWNLOAD"], "1")
        self.assertEqual(environment["NO_COLOR"], "1")

    def test_identity_prefers_hyphenated_headers_and_uses_metadata_fallbacks(self) -> None:
        identity = codex_request_identity(
            {
                "session-id": " session-from-header ",
                "thread-id": "thread-from-header",
                # Underscored HTTP headers are not part of the Codex protocol.
                "session_id": "spoofed-session",
                "thread_id": "spoofed-thread",
            },
            {
                "client_metadata": {
                    "session_id": "session-from-body",
                    "thread_id": "thread-from-body",
                    "turn_id": "turn-from-body",
                }
            },
        )

        self.assertEqual(
            identity,
            CodexRequestIdentity(
                session_id="session-from-header",
                thread_id="thread-from-header",
                turn_id="turn-from-body",
            ),
        )
        self.assertEqual(identity.chain_key, ("session-from-header", "turn-from-body"))

    def test_identity_reads_json_turn_metadata(self) -> None:
        identity = codex_request_identity(
            {},
            {
                "client_metadata": {
                    "x-codex-turn-metadata": json.dumps(
                        {
                            "session_id": "session-nested",
                            "thread_id": "thread-nested",
                            "turn_id": "turn-nested",
                        }
                    )
                }
            },
        )

        self.assertEqual(identity.session_id, "session-nested")
        self.assertEqual(identity.thread_id, "thread-nested")
        self.assertEqual(identity.turn_id, "turn-nested")

    def test_identity_reads_compact_turn_metadata_from_http_header(self) -> None:
        identity = codex_request_identity(
            {
                "session-id": "session-compact",
                "x-codex-turn-metadata": json.dumps(
                    {
                        "thread_id": "thread-compact",
                        "turn_id": "turn-compact",
                    }
                ),
            },
            {},
        )

        self.assertEqual(identity.session_id, "session-compact")
        self.assertEqual(identity.thread_id, "thread-compact")
        self.assertEqual(identity.turn_id, "turn-compact")

    def test_tool_declarations_cover_function_custom_namespace_and_omissions(self) -> None:
        declarations = copilot_tool_declarations(
            {
                "tools": [
                    {
                        "type": "function",
                        "name": "inspect_repo",
                        "description": "Inspect the repository",
                        "parameters": {
                            "type": "object",
                            "properties": {"path": {"type": "string"}},
                            "required": ["path"],
                        },
                    },
                    {
                        "type": "custom",
                        "name": "apply_patch",
                        "description": "Apply a patch",
                        "format": {"type": "grammar", "syntax": "lark", "definition": "start: /.+/"},
                    },
                    {
                        "type": "namespace",
                        "name": "mcp__workspace",
                        "tools": [
                            {
                                "type": "function",
                                "function": {
                                    "name": "read_file",
                                    "description": "Read a file",
                                    "parameters": {
                                        "type": "object",
                                        "properties": {"path": {"type": "string"}},
                                    },
                                },
                            }
                        ],
                    },
                    {"type": "tool_search", "name": "tool_search"},
                    {"type": "web_search_preview"},
                ]
            }
        )

        self.assertEqual(
            [declaration.sdk_name for declaration in declarations],
            ["inspect_repo", "apply_patch", "mcp__workspace__read_file"],
        )
        inspect_repo, apply_patch, read_file = declarations
        self.assertEqual(inspect_repo.output_type, "function_call")
        self.assertEqual(inspect_repo.parameters["required"], ["path"])
        self.assertEqual(apply_patch.output_type, "custom_tool_call")
        self.assertEqual(apply_patch.parameters["required"], ["input"])
        self.assertFalse(apply_patch.parameters["additionalProperties"])
        self.assertTrue(apply_patch.overrides_builtin)
        self.assertEqual(read_file.name, "read_file")
        self.assertEqual(read_file.namespace, "mcp__workspace")

    def test_transcript_preserves_tool_requests_and_results(self) -> None:
        transcript = copilot_transcript(
            {
                "input": [
                    {
                        "type": "message",
                        "role": "user",
                        "content": [{"type": "input_text", "text": "Fix the test"}],
                    },
                    {
                        "type": "function_call",
                        "call_id": "call_read",
                        "namespace": "mcp__workspace",
                        "name": "read_file",
                        "arguments": '{"path":"test.py"}',
                    },
                    {
                        "type": "function_call_output",
                        "call_id": "call_read",
                        "output": "old contents",
                    },
                    {
                        "type": "custom_tool_call",
                        "call_id": "call_patch",
                        "name": "apply_patch",
                        "input": "*** Begin Patch",
                    },
                    {
                        "type": "custom_tool_call_output",
                        "call_id": "call_patch",
                        "output": "Done!",
                    },
                ]
            }
        )

        self.assertIn("[USER]\nFix the test", transcript)
        self.assertIn(
            '[ASSISTANT TOOL REQUEST call_read]\nmcp__workspace.read_file: {"path":"test.py"}',
            transcript,
        )
        self.assertIn("[TOOL RESULT call_read]\nold contents", transcript)
        self.assertIn("[ASSISTANT TOOL REQUEST call_patch]\napply_patch: *** Begin Patch", transcript)
        self.assertIn("[TOOL RESULT call_patch]\nDone!", transcript)

    def test_cursor_fallback_key_is_not_reused_by_unrelated_byok_models(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            settings_path = root / "models.json"
            cursor_key_path = root / "cursor-api-key"
            cursor_key_path.write_text("cursor-secret\n")
            settings_path.write_text(
                json.dumps(
                    {
                        "models": [
                            {
                                "slug": "generic",
                                "provider": "anthropic",
                                "base_url": "https://api.anthropic.com/v1",
                                "model": "example",
                            },
                            {
                                "slug": "cursor-byok",
                                "provider": "cursor",
                                "base_url": "https://api2.cursor.sh/v1",
                                "model": "example",
                            },
                        ]
                    }
                )
            )
            with (
                patch.object(settings_module, "DEFAULT_CURSOR_API_KEY_FILE", cursor_key_path),
                patch.dict(
                    settings_module.os.environ,
                    {"CURSOR_API_KEY": "", "CURSOR_ACCESS_TOKEN": ""},
                    clear=False,
                ),
            ):
                models = settings_module.ModelSettings(settings_path).load()

        self.assertEqual(models[0].api_key, "")
        self.assertEqual(models[1].api_key, "cursor-secret")

    def test_auth_failure_invalidates_the_disk_model_cache(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            cache_path = Path(temporary_directory) / "copilot-models.json"
            cache_path.write_text(
                json.dumps(
                    {
                        "fetched_at": 9_999_999_999,
                        "models": [
                            {"slug": "copilot-stale", "id": "stale", "name": "Stale"}
                        ],
                    }
                )
            )
            discover = AsyncMock(
                side_effect=copilot_module.CopilotAuthenticationError("Not authenticated")
            )
            with (
                patch.object(copilot_module, "_model_cache", None),
                patch.object(copilot_module, "_last_model_error", "Not checked"),
                patch.object(copilot_module, "copilot_sdk_available", return_value=True),
                patch.object(copilot_module, "copilot_cli_path", return_value="/bin/true"),
                patch.object(copilot_module, "_discover_copilot_models", discover),
                patch.dict(
                    copilot_module.os.environ,
                    {
                        "CODEX_SHIM_COPILOT_MODEL_CACHE": str(cache_path),
                        "CODEX_SHIM_DISABLE_COPILOT": "",
                    },
                    clear=False,
                ),
            ):
                records = copilot_module.copilot_models(force_refresh=True)

            self.assertEqual(records, [])
            self.assertFalse(cache_path.exists())


class _FakePendingTools:
    def __init__(self) -> None:
        self.requests: list[object] = []

    async def handle_pending_tool_call(self, request: object) -> object:
        self.requests.append(request)
        return SimpleNamespace(success=True)


class _FakeSDKSession:
    def __init__(self, session_id: str = "sdk-session") -> None:
        self.session_id = session_id
        self.pending_tools = _FakePendingTools()
        self.rpc = SimpleNamespace(tools=self.pending_tools)
        self.aborted = False
        self.disconnected = False
        self.sent: list[str] = []

    async def send(self, message: str) -> None:
        self.sent.append(message)

    async def abort(self) -> None:
        self.aborted = True

    async def disconnect(self) -> None:
        self.disconnected = True


class _FakeSDKClient:
    def __init__(self) -> None:
        self.deleted_sessions: list[str] = []
        self.started = False
        self.stopped = False
        self.created_session_kwargs: list[dict[str, object]] = []
        self.created_sessions: list[_FakeSDKSession] = []

    async def start(self) -> None:
        self.started = True

    async def get_status(self) -> object:
        return SimpleNamespace(protocolVersion=3)

    async def get_auth_status(self) -> object:
        return SimpleNamespace(isAuthenticated=True, statusMessage="Signed in")

    async def create_session(self, **kwargs: object) -> _FakeSDKSession:
        session = _FakeSDKSession(f"sdk-created-{len(self.created_sessions) + 1}")
        self.created_session_kwargs.append(kwargs)
        self.created_sessions.append(session)
        return session

    async def delete_session(self, session_id: str) -> None:
        self.deleted_sessions.append(session_id)

    async def stop(self) -> None:
        self.stopped = True


class _DeadSDKClient(_FakeSDKClient):
    async def get_status(self) -> object:
        raise RuntimeError("connection closed")


class _BlockingDeleteSDKClient(_FakeSDKClient):
    def __init__(self) -> None:
        super().__init__()
        self.delete_started = asyncio.Event()
        self.allow_delete = asyncio.Event()

    async def delete_session(self, session_id: str) -> None:
        self.deleted_sessions.append(session_id)
        self.delete_started.set()
        await self.allow_delete.wait()


class CopilotBridgeRoundTripTests(unittest.IsolatedAsyncioTestCase):
    async def test_session_allowlists_only_codex_declared_tools(self) -> None:
        identity = CodexRequestIdentity("session-tools", "thread-tools", "turn-tools")
        body = {
            "model": "copilot-test-model",
            "input": [{"type": "message", "role": "user", "content": "Inspect"}],
            "tools": [
                {
                    "type": "function",
                    "name": "read_file",
                    "parameters": {"type": "object", "properties": {}},
                },
                {"type": "custom", "name": "apply_patch"},
            ],
        }
        client = _FakeSDKClient()
        bridge = CopilotBridge()
        bridge._client = client

        with patch.object(
            copilot_module,
            "copilot_model_record",
            return_value={"id": "test-model", "reasoning_effort": False},
        ):
            bridge_session = await bridge._create_session(body, identity)

        self.assertEqual(len(client.created_session_kwargs), 1)
        self.assertEqual(
            client.created_session_kwargs[0]["available_tools"],
            ["custom:read_file", "custom:apply_patch"],
        )
        self.assertEqual(client.created_sessions[0].sent, [copilot_transcript(body)])
        self.assertIs(bridge_session.sdk_session, client.created_sessions[0])
        await bridge.close()

    async def test_parallel_pending_calls_resume_once_and_rounds_are_idempotent(self) -> None:
        from copilot.session_events import (
            AssistantMessageData,
            AssistantMessageDeltaData,
            AssistantMessageToolRequest,
            AssistantUsageData,
            ExternalToolRequestedData,
            SessionIdleData,
        )

        identity = CodexRequestIdentity("session-1", "thread-1", "turn-1")
        first_body = {
            "model": "copilot-test-model",
            "stream": True,
            "input": [{"type": "message", "role": "user", "content": "Inspect and patch"}],
            "tools": [
                {
                    "type": "function",
                    "name": "read_file",
                    "parameters": {
                        "type": "object",
                        "properties": {"path": {"type": "string"}},
                    },
                },
                {"type": "custom", "name": "apply_patch"},
            ],
        }
        declarations = {
            declaration.sdk_name: declaration
            for declaration in copilot_tool_declarations(first_body)
        }
        fake_session = _FakeSDKSession()
        sdk_events: asyncio.Queue[object] = asyncio.Queue()
        bridge_session = _BridgeSession(fake_session, identity, declarations, sdk_events)

        def event(data: object) -> object:
            return SimpleNamespace(data=data)

        await sdk_events.put(
            event(
                AssistantMessageData(
                    content="",
                    message_id="message-tools",
                    tool_requests=[
                        AssistantMessageToolRequest(name="read_file", tool_call_id="call-read"),
                        AssistantMessageToolRequest(name="apply_patch", tool_call_id="call-patch"),
                    ],
                )
            )
        )
        await sdk_events.put(
            event(
                ExternalToolRequestedData(
                    request_id="request-read",
                    session_id="sdk-session",
                    tool_call_id="call-read",
                    tool_name="read_file",
                    arguments={"path": "example.py"},
                )
            )
        )
        await sdk_events.put(
            event(
                ExternalToolRequestedData(
                    request_id="request-patch",
                    session_id="sdk-session",
                    tool_call_id="call-patch",
                    tool_name="apply_patch",
                    arguments={"input": "*** Begin Patch"},
                )
            )
        )
        # These events belong to the continuation after Codex returns both results.
        await sdk_events.put(event(AssistantMessageDeltaData("Patched.", "message-final")))
        await sdk_events.put(event(AssistantUsageData(model="test", input_tokens=7, output_tokens=3)))
        await sdk_events.put(event(SessionIdleData()))

        bridge = CopilotBridge()
        fake_client = _FakeSDKClient()
        bridge._client = fake_client

        async def create_session(_body: object, _identity: object) -> _BridgeSession:
            bridge._turn_sessions[identity.chain_key] = bridge_session
            return bridge_session

        create_session_mock = AsyncMock(side_effect=create_session)
        with patch.object(bridge, "_create_session", create_session_mock):
            first_events = [item async for item in bridge.events(first_body, identity)]
            replayed_first_events = [item async for item in bridge.events(first_body, identity)]

            self.assertEqual(first_events, replayed_first_events)
            create_session_mock.assert_awaited_once()
            tool_calls = [item for item in first_events if item.kind == "tool_call"]
            self.assertEqual([item.call_id for item in tool_calls], ["call-read", "call-patch"])
            self.assertEqual(tool_calls[0].arguments, '{"path":"example.py"}')
            self.assertEqual(tool_calls[0].output_type, "function_call")
            self.assertEqual(tool_calls[1].input, "*** Begin Patch")
            self.assertEqual(tool_calls[1].output_type, "custom_tool_call")

            continuation_body = {
                **first_body,
                "input": [
                    *first_body["input"],
                    {
                        "type": "function_call_output",
                        "call_id": "call-read",
                        "output": "file contents",
                    },
                    {
                        "type": "custom_tool_call_output",
                        "call_id": "call-patch",
                        "output": "Done!",
                    },
                ],
            }
            continuation_events = [
                item async for item in bridge.events(continuation_body, identity)
            ]
            replayed_continuation = [
                item async for item in bridge.events(continuation_body, identity)
            ]

        self.assertEqual(continuation_events, replayed_continuation)
        self.assertEqual([item.kind for item in continuation_events], ["text_delta", "usage", "done"])
        self.assertEqual(continuation_events[0].text, "Patched.")
        self.assertEqual(
            continuation_events[1].usage,
            {"input_tokens": 7, "output_tokens": 3, "total_tokens": 10},
        )
        self.assertEqual(len(fake_session.pending_tools.requests), 2)
        self.assertEqual(
            [request.request_id for request in fake_session.pending_tools.requests],
            ["request-read", "request-patch"],
        )
        self.assertEqual(
            [request.result for request in fake_session.pending_tools.requests],
            ["file contents", "Done!"],
        )
        self.assertFalse(fake_session.aborted)
        self.assertTrue(fake_session.disconnected)
        self.assertEqual(fake_client.deleted_sessions, ["sdk-session"])
        await bridge.close()
        self.assertTrue(fake_client.stopped)

    async def test_same_call_id_is_resolved_only_in_its_own_codex_turn(self) -> None:
        identity_a = CodexRequestIdentity("session-a", "thread-a", "turn-a")
        identity_b = CodexRequestIdentity("session-b", "thread-b", "turn-b")
        sdk_a = _FakeSDKSession("sdk-a")
        sdk_b = _FakeSDKSession("sdk-b")
        session_a = _BridgeSession(sdk_a, identity_a, {}, asyncio.Queue())
        session_b = _BridgeSession(sdk_b, identity_b, {}, asyncio.Queue())
        session_a.pending["same-call-id"] = _PendingTool("request-a", "same-call-id", session_a)
        session_b.pending["same-call-id"] = _PendingTool("request-b", "same-call-id", session_b)

        bridge = CopilotBridge()
        bridge._turn_sessions[identity_a.chain_key] = session_a
        bridge._turn_sessions[identity_b.chain_key] = session_b
        cached = _CachedRound()
        body = {
            "input": [
                {
                    "type": "function_call_output",
                    "call_id": "same-call-id",
                    "output": "result-a",
                }
            ]
        }
        with patch.object(bridge, "_consume_session", new=AsyncMock()):
            await bridge._run_round(cached, body, identity_a)

        self.assertEqual(
            [request.request_id for request in sdk_a.pending_tools.requests],
            ["request-a"],
        )
        self.assertEqual(sdk_b.pending_tools.requests, [])
        self.assertIn("same-call-id", session_b.pending)
        await bridge.close()

    async def test_parallel_tool_collection_waits_for_every_declared_sibling(self) -> None:
        from copilot.session_events import (
            AssistantMessageData,
            AssistantMessageToolRequest,
            ExternalToolRequestedData,
        )

        identity = CodexRequestIdentity("session-parallel", "thread-parallel", "turn-parallel")
        body = {
            "tools": [
                {"type": "function", "name": "first_tool"},
                {"type": "function", "name": "second_tool"},
            ]
        }
        declarations = {
            declaration.sdk_name: declaration
            for declaration in copilot_tool_declarations(body)
        }
        sdk_session = _FakeSDKSession("sdk-parallel")
        queue: asyncio.Queue[object] = asyncio.Queue()
        bridge_session = _BridgeSession(sdk_session, identity, declarations, queue)
        await queue.put(
            SimpleNamespace(
                data=AssistantMessageData(
                    content="",
                    message_id="parallel-message",
                    tool_requests=[
                        AssistantMessageToolRequest(name="first_tool", tool_call_id="call-first"),
                        AssistantMessageToolRequest(name="second_tool", tool_call_id="call-second"),
                    ],
                )
            )
        )
        await queue.put(
            SimpleNamespace(
                data=ExternalToolRequestedData(
                    request_id="request-first",
                    session_id="sdk-parallel",
                    tool_call_id="call-first",
                    tool_name="first_tool",
                    arguments={},
                )
            )
        )

        async def add_delayed_sibling() -> None:
            await asyncio.sleep(0.02)
            await queue.put(
                SimpleNamespace(
                    data=ExternalToolRequestedData(
                        request_id="request-second",
                        session_id="sdk-parallel",
                        tool_call_id="call-second",
                        tool_name="second_tool",
                        arguments={},
                    )
                )
            )

        producer = asyncio.create_task(add_delayed_sibling())
        bridge = CopilotBridge()
        cached = _CachedRound()
        with patch(
            "codex_shim.copilot_passthrough._PARALLEL_TOOL_QUIET_SECONDS",
            0.005,
        ):
            await bridge._consume_session(cached, bridge_session)
        await producer

        calls = [event.call_id for event in cached.events if event.kind == "tool_call"]
        self.assertEqual(calls, ["call-first", "call-second"])
        await bridge._discard_session(bridge_session)

    async def test_close_deletes_an_active_sdk_session_before_stopping_client(self) -> None:
        identity = CodexRequestIdentity("session-close", "thread-close", "turn-close")
        sdk_session = _FakeSDKSession("sdk-close")
        bridge_session = _BridgeSession(sdk_session, identity, {}, asyncio.Queue())
        client = _FakeSDKClient()
        bridge = CopilotBridge()
        bridge._client = client
        bridge._turn_sessions[identity.chain_key] = bridge_session

        await bridge.close()

        self.assertTrue(sdk_session.aborted)
        self.assertTrue(sdk_session.disconnected)
        self.assertEqual(client.deleted_sessions, ["sdk-close"])
        self.assertTrue(client.stopped)

    async def test_close_drains_delete_after_round_cancellation(self) -> None:
        identity = CodexRequestIdentity("session-race", "thread-race", "turn-race")
        sdk_session = _FakeSDKSession("sdk-race")
        client = _BlockingDeleteSDKClient()
        bridge_session = _BridgeSession(
            sdk_session,
            identity,
            {},
            asyncio.Queue(),
            client=client,
        )
        bridge = CopilotBridge()
        bridge._client = client
        bridge._turn_sessions[identity.chain_key] = bridge_session
        cached = _CachedRound()
        cached.task = asyncio.create_task(bridge._finish_turn(bridge_session))
        bridge._rounds["finishing-round"] = cached

        await asyncio.wait_for(client.delete_started.wait(), timeout=1.0)
        close_task = asyncio.create_task(bridge.close())
        await asyncio.sleep(0)

        self.assertFalse(close_task.done())
        self.assertFalse(client.stopped)
        client.allow_delete.set()
        await asyncio.wait_for(close_task, timeout=1.0)

        self.assertEqual(client.deleted_sessions, ["sdk-race"])
        self.assertTrue(sdk_session.disconnected)
        self.assertTrue(client.stopped)

    async def test_dead_runtime_is_replaced_before_the_next_session(self) -> None:
        dead_client = _DeadSDKClient()
        fresh_client = _FakeSDKClient()
        bridge = CopilotBridge()
        bridge._client = dead_client

        with (
            patch("codex_shim.copilot_passthrough.copilot_cli_path", return_value="/bin/true"),
            patch("codex_shim.copilot_passthrough.copilot_sdk_available", return_value=True),
            patch("copilot.CopilotClient", return_value=fresh_client),
        ):
            client = await bridge._ensure_client()

        self.assertIs(client, fresh_client)
        self.assertTrue(dead_client.stopped)
        self.assertTrue(fresh_client.started)
        await bridge.close()

    def test_reasoning_effort_is_gated_by_discovered_model_capabilities(self) -> None:
        body = {"reasoning": {"effort": "high"}}
        self.assertIsNone(_reasoning_effort(body, {"reasoning_effort": False}))
        self.assertIsNone(
            _reasoning_effort(
                body,
                {
                    "reasoning_effort": True,
                    "supported_reasoning_efforts": ["low", "medium"],
                },
            )
        )
        self.assertEqual(
            _reasoning_effort(
                body,
                {
                    "reasoning_effort": True,
                    "supported_reasoning_efforts": ["high"],
                },
            ),
            "high",
        )


class _RecordingStreamResponse:
    def __init__(self) -> None:
        self.writes: list[bytes] = []

    async def write(self, data: bytes) -> None:
        self.writes.append(data)

    def payloads(self) -> list[dict[str, object]]:
        payloads: list[dict[str, object]] = []
        for record in b"".join(self.writes).split(b"\n\n"):
            if not record.startswith(b"data: ") or record == b"data: [DONE]":
                continue
            payloads.append(json.loads(record[len(b"data: ") :]))
        return payloads


class CopilotResponsesStreamTests(unittest.IsolatedAsyncioTestCase):
    async def test_compact_requests_get_isolated_sdk_turns(self) -> None:
        identities: list[CodexRequestIdentity] = []

        async def events(_body, identity):
            identities.append(identity)
            if False:
                yield None

        server = server_module.ShimServer.__new__(server_module.ShimServer)
        server.copilot_bridge = SimpleNamespace(events=events)
        request = SimpleNamespace(
            headers={
                "session-id": "session-compact",
                "x-codex-turn-metadata": json.dumps({"turn_id": "turn-compact"}),
            }
        )

        with patch.object(server_module, "copilot_upstream_model", return_value="gpt-example"):
            for _ in range(2):
                response = await server._copilot_passthrough(
                    request,
                    {"model": "copilot-example", "input": []},
                    force_non_stream=True,
                    isolate_session=True,
                )
                self.assertEqual(response.status, 200)

        self.assertEqual(len(identities), 2)
        self.assertEqual(identities[0].session_id, "session-compact")
        self.assertTrue(identities[0].turn_id.startswith("turn-compact:compact:"))
        self.assertNotEqual(identities[0].chain_key, identities[1].chain_key)

    async def test_stale_copilot_selection_returns_login_error_before_sse(self) -> None:
        server = server_module.ShimServer.__new__(server_module.ShimServer)
        unavailable = copilot_module.CopilotUnavailableError(
            "Copilot model 'copilot-stale' is unavailable. Run `copilot login`, then restart codex-shim."
        )

        with (
            patch.object(server_module, "copilot_upstream_model", side_effect=unavailable),
            patch.object(server_module, "copilot_models", return_value=[]),
        ):
            response = await server._copilot_passthrough(
                SimpleNamespace(),
                {"model": "copilot-stale", "stream": True},
            )

        self.assertEqual(response.status, 401)
        payload = json.loads(response.text)
        self.assertEqual(payload["error"]["type"], "copilot_unavailable")
        self.assertIn("copilot login", payload["error"]["message"])

    async def test_custom_tool_call_uses_responses_custom_input_events_and_fields(self) -> None:
        response = _RecordingStreamResponse()
        state = ResponsesStreamState("copilot-test")

        await state.start(response)  # type: ignore[arg-type]
        await state.write_external_tool_call(
            response,  # type: ignore[arg-type]
            call_id="call-patch",
            name="apply_patch",
            namespace="",
            arguments="",
            custom_input="*** Begin Patch\n*** End Patch",
            output_type="custom_tool_call",
        )
        await state.finish(response)  # type: ignore[arg-type]

        payloads = response.payloads()
        added = next(payload for payload in payloads if payload["type"] == "response.output_item.added")
        delta = next(
            payload
            for payload in payloads
            if payload["type"] == "response.custom_tool_call_input.delta"
        )
        input_done = next(
            payload
            for payload in payloads
            if payload["type"] == "response.custom_tool_call_input.done"
        )
        item_done = next(payload for payload in payloads if payload["type"] == "response.output_item.done")
        completed = next(payload for payload in payloads if payload["type"] == "response.completed")

        self.assertEqual(added["item"]["type"], "custom_tool_call")
        self.assertEqual(added["item"]["input"], "")
        self.assertNotIn("arguments", added["item"])
        self.assertEqual(delta["delta"], "*** Begin Patch\n*** End Patch")
        self.assertEqual(input_done["input"], "*** Begin Patch\n*** End Patch")
        self.assertEqual(item_done["item"]["input"], "*** Begin Patch\n*** End Patch")
        self.assertNotIn("arguments", item_done["item"])
        self.assertEqual(completed["response"]["status"], "completed")
        self.assertEqual(completed["response"]["output"], [item_done["item"]])
        self.assertEqual(response.writes[-1], b"data: [DONE]\n\n")

    async def test_chat_style_custom_tool_never_emits_function_argument_events(self) -> None:
        response = _RecordingStreamResponse()
        state = ResponsesStreamState("copilot-test", tool_types={"apply_patch": "custom"})

        await state.start(response)  # type: ignore[arg-type]
        await state.write_chat_delta(
            response,  # type: ignore[arg-type]
            {
                "choices": [
                    {
                        "delta": {
                            "tool_calls": [
                                {
                                    "index": 0,
                                    "id": "call-patch",
                                    "function": {
                                        "name": "apply_patch",
                                        "arguments": '{"input":"*** Begin Patch"}',
                                    },
                                }
                            ]
                        }
                    }
                ]
            },
        )
        await state.finish(response)  # type: ignore[arg-type]

        payloads = response.payloads()
        event_types = [payload["type"] for payload in payloads]
        self.assertNotIn("response.function_call_arguments.delta", event_types)
        item_done = next(payload for payload in payloads if payload["type"] == "response.output_item.done")
        self.assertEqual(item_done["item"]["type"], "custom_tool_call")
        self.assertEqual(item_done["item"]["input"], "*** Begin Patch")
        self.assertNotIn("arguments", item_done["item"])


if __name__ == "__main__":
    unittest.main()
