# SCR-021: Intelligence seams and chat
Status: Applied (1.2.0).
Reason: Earmark 1.2.0 "Workspace" (specs/releases/workspace-plan.md).
Change: `ChatMessage`, `ChatSource`, `ChatScope`, `ChatRepository`, `IntelligenceAvailability`, `IntelligenceError`.
Persistence: New table `chatMessage`. Chat sources are produced by Earmark from retrieved text, never taken from the model output. Migration `v4-workspace` is append-only; downgrading after it is unsupported.
