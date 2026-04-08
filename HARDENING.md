You are doing a deep bug audit of this codebase. 

Do NOT make any changes yet. First, produce a prioritized list of:
- Logic errors and edge cases
- Unhandled errors and missing null checks  
- Race conditions or async issues
- Off-by-one errors
- Incorrect assumptions about data shape or types
- Dead code that may mask real bugs
- Security-relevant issues (input validation, injection, etc.)

For each finding, write: the file and line, what the bug is, and why it's a problem into FIXES.md
