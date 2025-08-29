---
description: "Create a story document for the next milestone from an implementation plan"
allowed_tools: ["Read", "Write", "Glob", "LS"]
---

# Create Story from Implementation Plan

You are tasked with creating a story document for the next milestone from an implementation plan.

## User Input:
```
$ARGUMENTS
```

Parse the user input above for:
- Plan file path (e.g., "docs/raid0_implementation_plan.md")
- Milestone number (e.g., "1.2", "2.0")  
- Topic name override
- Any other relevant information

## Process:

1. **Find Implementation Plan**:
   - First check user input for plan file path
   - If not provided, search for files matching `*plan*.md`, `*roadmap*.md`, `*milestone*.md` in current directory and `docs/`
   - If multiple plans found, ask user to choose
   - If no plan found, ask user for the path

2. **Parse Milestones**:
   - Look for milestone headers like `## Milestone 1.1`, `### Milestone 2.0`
   - Extract milestone ID and title

3. **Check Existing Stories**:
   - List files in `docs/stories/` 
   - Identify which milestones already have stories (format: `<topic>-story-<milestone>.md`)
   - Read existing related stories (same topic) to review Developer Logs sections
   - Extract key decisions, deviations, and lessons learned that may impact the new story

4. **Select Next Milestone**:
   - First check user input for specific milestone number
   - If not provided, find the first milestone without a story
   - If multiple available, ask user which one

5. **Extract Topic**:
   - Get topic name from plan filename (remove `_implementation_plan.md`, `_plan.md`, etc.)

6. **Create Story Document**:
   - Generate filename: `docs/stories/<topic>-story-<milestone>.md`
   - Use the story template below
   - Include relevant insights from previous stories' developer logs in Technical Notes
   - Reference any decisions or deviations that may influence this milestone

## Story Template:

```markdown
# Milestone {milestone_id} Story: {milestone_title}

## Story Overview
This story implements milestone {milestone_id}: {milestone_title}

**Source Plan**: `{plan_file_path}`

## Tasks & Sub-tasks

### Task 1: [Task Name]
- [ ] Sub-task 1
- [ ] Sub-task 2
- [ ] Sub-task 3

### Task 2: [Task Name]  
- [ ] Sub-task 1
- [ ] Sub-task 2

## Deliverables
1. [Deliverable 1]
2. [Deliverable 2]
3. [Deliverable 3]

## Technical Notes
[Add architectural or implementation guidance when needed]

## Status
Not Started

## Dependencies
[List any prerequisite stories or items - remove if none]

## Definition of Done
[Add 2-3 clear completion criteria - remove if not needed]

## References
[Links to relevant docs/issues - remove if not needed]

## Developer Logs

### Decision Log
[Key technical decisions and rationale]

### Blockers Encountered
[Issues faced and how they were resolved]

### Deviations from Plan
[What changed from original plan and why]

### Lessons Learned
[Insights for future stories]
```

## Instructions:
- Break down the milestone into self-contained tasks
- Each task should represent complete functionality (implementation + testing is fine to split)
- Use `[ ]` checkboxes for all tasks and sub-tasks
- Keep stories concise and simple
- Fill in placeholders with actual content from the plan
- Create the story file and confirm successful creation

