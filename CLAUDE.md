# Global Claude Code Preferences

## Stack
Primary work: Native macOS apps in SwiftUI, Swift. Moving toward Supabase backend.

## Style
- Responses should be short and direct — no trailing summaries of what was just done
- No emojis
- When showing code changes, show diffs or targeted edits — not full file rewrites unless necessary
- Prefer fixing root causes over workarounds
- Run the code-review skill on any code change or addition before committing, and again before deploying to production — every size of change, not just large ones. Point it explicitly at the correct repo/path rather than assuming cwd.
- When asked to draft a file (report, doc, one-off deliverable), write it directly to `~/Desktop` — never publish as a claude.ai Artifact (requires sign-in, which the user doesn't want). Just tell the user the file location.

## Projects
- Cozumel Manager: vacation rental management app for properties in Cozumel, MX
