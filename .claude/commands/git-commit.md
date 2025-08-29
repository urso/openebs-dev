---
description: "Generate conventional commit messages based on staged changes and project standards"
argument-hint: "Optional: additional context or specific focus for the commit message"
allowed_tools: ["Bash", "Read", "Glob", "Grep", "LS"]
---

# Git Commit Message Generator

Analyzes staged changes and generates conventional commit messages that adhere to the project's commit standards.

## User Input:
```
$ARGUMENTS
```

## Project Commit Standards

This project uses conventional commits with the following requirements:

### Valid Commit Types:
- `build`: Changes that affect the build system or external dependencies
- `chore`: Routine tasks, maintenance, or housekeeping changes
- `ci`: Changes to CI configuration files and scripts
- `docs`: Documentation changes only
- `feat`: New features or functionality
- `fix`: Bug fixes
- `perf`: Performance improvements
- `refactor`: Code changes that neither fix bugs nor add features
- `revert`: Reverts a previous commit
- `style`: Code style changes (formatting, missing semi-colons, etc.)
- `test`: Adding or modifying tests
- `example`: Changes to example code or configurations

### Format Requirements:
- **Header format**: `type(scope): subject`
- **Header max length**: 100 characters
- **Subject max length**: 80 characters
- **Subject min length**: 5 characters
- **Subject case**: lower-case (no sentence-case, start-case, pascal-case, upper-case)
- **Subject ending**: Never end with a period
- **Scope**: Optional, should be lower-case if used
- **Body**: Optional, max 100 characters per line, requires leading blank line
- **Footer**: Optional, max 100 characters per line, should have leading blank line

### Prohibited Patterns:
- Never include "code-review", "review comment", "address comment", or "addressed comment" in subject
- These should be squashed into the parent commit instead

## Instructions:

1. **Analyze Staged Changes**:
   - Run `git diff --cached --stat` to get overview of changed files
   - Run `git diff --cached --name-only` to get list of changed files
   - Run `git diff --cached` to examine actual changes (limit output if very large)

2. **Determine Commit Type**:
   - Analyze the nature of changes to determine appropriate type
   - Consider file paths and content changes
   - Default to `feat` for new functionality, `fix` for bug fixes, `refactor` for code improvements

3. **Generate Scope** (if applicable):
   - Look at file paths to determine logical scope
   - Use lower-case format
   - Examples: `pool`, `api`, `storage`, `controller`, etc.
   - Keep scope concise and meaningful

4. **Create Subject**:
   - Summarize what the change accomplishes
   - Use imperative mood (e.g., "add", "fix", "update", not "added", "fixed", "updated")
   - Keep within 80 characters
   - Use lower-case
   - Be specific but concise

5. **Generate Body** (if needed):
   - Explain WHY the change was made, not what was changed
   - Include any breaking changes or important notes
   - Use bullet points for multiple items
   - Wrap lines at 100 characters

6. **Consider User Input**:
   - If user provided additional context in `$ARGUMENTS`, incorporate it appropriately
   - Use user input to refine the commit message focus or add missing context

7. **Present Initial Suggestion**:
   - Show the proposed commit message clearly
   - Explain the reasoning behind type and scope selection
   - Ask if user wants any adjustments

8. **Iterate on Message**:
   - Allow user to request changes to type, scope, subject, or body
   - Refine the message based on user feedback
   - Ensure final message still adheres to all project standards

9. **Offer to Execute Commit**:
   - Once user is satisfied with the commit message, ask: "Shall I run `git commit` with this message on your behalf?"
   - If user agrees, execute `git commit -m "the final message"`
   - If user declines, remind them they can copy the message and run `git commit` manually

## Example Interaction Flow:

```
Based on your staged changes, I suggest this commit message:

**Type**: feat
**Scope**: pool
**Subject**: add disk space management for storage pools

**Full commit message**:
```
feat(pool): add disk space management for storage pools

Implements automatic capacity monitoring and ENOSPC recovery
mechanisms to prevent storage pool exhaustion and improve
reliability during high-usage scenarios.
```

**Reasoning**: 
- Type `feat` because this adds new functionality
- Scope `pool` based on the modified files in pool-related directories
- Subject focuses on the main capability being added

Would you like any adjustments to this commit message?

[After user is satisfied]

Shall I run `git commit` with this message on your behalf?
```

Remember: Always validate that there are staged changes before attempting to commit.