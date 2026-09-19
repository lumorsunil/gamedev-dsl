# continuations-as-values

```zig
const Continuation = struct {
    ip: usize,
    stack_frames: []const StackFrame,
}; 
```

## calling a normal function

1. Push 1 stack frame
2. Populate arguments
3. Jump to function body

## calling a continuation function

1. Push stacks from continuation state
2. Jump to function body

## todo

- [ ] move continuations from special stack frame slot to handler operations argument
- [ ] implement special call continuation instruction
