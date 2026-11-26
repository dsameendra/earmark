# SCR-020: Attachments
Status: Applied (1.2.0).
Reason: Earmark 1.2.0 "Workspace" (specs/releases/workspace-plan.md).
Change: `Attachment`, `AttachmentPage`, `SlideLink`, `AttachmentRepository`. PDF and images only.
Persistence: New tables `attachment`, `attachmentPage`, `slideLink` and page-text FTS. Files are copied into the library under `Attachments/`. Migration `v4-workspace` is append-only; downgrading after it is unsupported.
