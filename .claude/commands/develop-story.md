---
description: "Develop tasks from a story document with planning and implementation"
allowed_tools: ["Read", "Write", "Edit", "Glob", "LS", "Task", "TodoWrite"]
---

# Develop Story Tasks

You will help develop tasks from a story document with comprehensive planning and implementation support.

## User Input:
```
$ARGUMENTS
```

## Process:

### 1. **Story Document Discovery**:
   - Parse user input for story document path or story name
   - If not provided, search `docs/stories/` for available story files
   - List available stories and let user choose if multiple exist
   - Read the selected story document to understand its structure

### 2. **Task Selection Phase**:
   - Display all tasks and sub-tasks from the story document with completion status
   - Ask user to specify which specific tasks they want to work on
   - **IMPORTANT**: Only work on the explicitly selected tasks - do not touch other tasks
   - Validate that selected tasks are not already completed

### 3. **Detailed Planning Phase**:
   - For each selected task, create a comprehensive development plan
   - Break down into implementation steps, identify files to modify, consider dependencies
   - Present the plan to the user for discussion and approval
   - **Do not proceed to implementation until the plan is explicitly approved**

### 4. **Implementation Phase** (only after plan approval):
   - Use a specialized sub-agent for actual implementation via Task tool with subagent_type: "general-purpose"
   - Provide detailed instructions including specific files, approach, testing, and integration considerations

### 5. **Story Document Updates**:
   - Mark completed tasks as ✅ in the story document
   - Update Developer Logs sections (Decision Log, Blockers, Deviations, Lessons Learned)
   - Update Status section to reflect current progress

### 6. **Progress Tracking**:
   - Use TodoWrite to track development progress with manageable todo items
   - Keep todos updated and mark completed immediately after finishing each step

## Key Guidelines:

- **Task Selection**: Only work on user-selected tasks, never touch others
- **Planning First**: Always plan before implementing, wait for explicit approval
- **Use Sub-agents**: Delegate complex implementation work appropriately  
- **Update Story**: Keep story document current with progress and insights
- **Stay Collaborative**: Keep user informed and ask for confirmation on major changes