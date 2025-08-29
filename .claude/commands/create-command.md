---
description: "Create a new Claude Code slash command interactively"
allowed_tools: ["Write", "LS"]
---

# Create Custom Slash Command

You will help create a new custom slash command for Claude Code through an interactive process.

## Claude Code Slash Command Reference

**File Location**: Commands must be saved as `.md` files in `.claude/commands/` directory.

**User Input Variable**: `$ARGUMENTS` - Contains the plain text user input after the command name. This is the only variable available (no positional parameters).

**Frontmatter Options** (YAML header):
- `description`: Brief description of what the command does (recommended)
- `allowed_tools`: Array of specific tools the command can use (optional - omit for default access)
- `argument-hint`: Hint text shown to user about expected arguments (optional)
- `model`: Specific model to use for the command (optional)

**Available Tools Reference**:
```
Tool            Permission Required    Example allowed_tools entry
Bash            Yes                   "Bash", "Bash(git *:*)", "Bash(ls:*)"  
Edit            Yes                   "Edit"
Glob            No                    "Glob" 
Grep            No                    "Grep"
LS              No                    "LS"
MultiEdit       Yes                   "MultiEdit"
NotebookEdit    Yes                   "NotebookEdit" 
Read            No                    "Read"
Task            No                    "Task"
TodoWrite       No                    "TodoWrite"
WebFetch        Yes                   "WebFetch"
WebSearch       Yes                   "WebSearch"
Write           Yes                   "Write"
```

**Note**: If `allowed_tools` is omitted, the command gets default conversational access. Only specify it if you need to restrict to specific tools or enable permission-required tools.

## User Input:
```
$ARGUMENTS
```

## Process:

1. **Parse Initial Input**:
   - Extract any command name, description, or details provided
   - Note what information is missing

2. **Interactive Information Gathering**:
   Ask questions to determine:
   
   **Essential Information:**
   - Command name (must be valid filename, no spaces/special chars)
   - Brief description for frontmatter
   - Detailed explanation of command purpose
   
   **Optional Information:**
   - Does it need an argument-hint for users?
   - Any specific behavior or constraints?

3. **Validate and Confirm**:
   - Check if command name is valid
   - Check if `.claude/commands/<name>.md` already exists (ask about overwrite)
   - Summarize what will be created and get confirmation

4. **Generate Command File**:
   - Create frontmatter with description (and argument-hint if provided)
   - Generate command content based on purpose
   - Write to `.claude/commands/<name>.md`
   - Confirm successful creation

## Command Structure Template:

```markdown
---
description: "Brief description of what this command does"
argument-hint: "expected input format (optional)"
---

# Command Title

Brief explanation of what the command does and its purpose.

## User Input:
```
$ARGUMENTS
```

Instructions for Claude on what to do with the user input.

[Additional sections as needed for complex commands like process steps, templates, etc.]
```

## Guidelines:
- Keep the initial command simple - users can add `allowed_tools` later if needed
- Always include the `$ARGUMENTS` section even if command doesn't require input
- Focus on clear, actionable instructions for Claude
- Ask clarifying questions if user input is unclear
- Validate command name and check for file conflicts
- Confirm successful file creation