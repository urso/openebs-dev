---
description: "Create an implementation plan based on discussions, research, or available documents"
argument-hint: "feature/topic description or reference to research documents"
---

# Create Implementation Plan

Create a comprehensive implementation plan based on discussions, research, or other available research documents. This command generates a structured plan document that serves as an intermediate step between high-level requirements and detailed story/task breakdown.

## User Input:
```
$ARGUMENTS
```

## Process:

1. **Gather Context and Requirements**:
   - Parse the user's initial requirements
   - Search for relevant research documents, discussions, or existing plans
   - Identify the scope and complexity of the feature/topic
   - Gather technical context from the codebase if applicable

2. **Collaborative Requirements Definition**:
   - Present findings and initial understanding to the user
   - Discuss and confirm the objective and high-level technical requirements
   - Identify any missing information or unclear requirements
   - **IMPORTANT**: Get user confirmation that all required information has been collected before proceeding to create the actual plan

3. **Create Structured Implementation Plan**:

   Use the following template structure based on `docs/raid0_implementation_plan.md`:

   ### Plan Structure:
   ```markdown
   # [Feature/Topic] Implementation Plan

   ## Project Overview
   **Objective**: [Clear statement of what needs to be accomplished]
   **Approach**: [High-level technical approach and strategy]

   ---

   ## Milestone 1: [Foundation/First Phase]
   ### 1.1 [First Major Task]
   **Objective**: [What this task accomplishes]
   **Tasks**:
   - [Specific actionable items]
   - [File changes or system modifications needed]
   
   **Files Modified**:
   - [List of files that will be changed]
   
   **Deliverables**:
   - ✅ [Concrete outcomes and success criteria]

   [Continue with additional milestones...]

   ---

   ## Technical Implementation Summary
   ### Code Changes Required
   [High-level summary of changes needed, focusing on simplicity]

   ### Key Technical Points
   [Important technical considerations and architectural decisions]

   ---

   ## Success Criteria
   ### Functional Requirements
   - ✅ [What the system must do functionally]

   ### Quality Requirements  
   - ✅ [Performance, reliability, testing requirements]

   ### Technical Requirements
   - ✅ [Architecture, design, and integration requirements]
   ```

4. **Plan Validation and Complexity Check**:
   - If the plan has many milestones (>6-7), warn the user that the problem may be too complex
   - Suggest breaking it down into multiple plans with an MVP approach
   - Recommend defining follow-up milestones/tasks to be addressed after MVP completion

5. **Save and Reference**:
   - Save the plan to `docs/[feature_name]_implementation_plan.md`
   - Create the plan document with proper markdown formatting
   - Ensure the plan serves as input for future story creation

## Guidelines:
- **Milestone Completeness**: Ensure milestones represent complete units of work. Never split the development of a single component across multiple milestones as this leads to inconsistencies
- **Focus on Implementation**: The plan should be development-focused with specific file paths and modification details
- **Simplicity**: Strive for simple, clear solutions without unnecessary complexity
- **No Time Estimates**: Avoid timeline predictions or line-of-code estimates
- **MVP Consideration**: For complex features, consider what constitutes a minimal viable implementation
- **Integration Points**: Consider backward compatibility and system integration requirements

The resulting plan should be detailed enough to serve as the foundation for creating specific development stories and tasks, with each milestone representing a cohesive, complete unit of functionality.