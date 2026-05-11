# 00 — References

The implementation language is Luau.

Reference pages:

```text
https://luau.org/
https://luau.org/syntax/
https://luau.org/types/
https://luau.org/library/
https://luau.org/news/
```

Applied rules:

- Use `--!strict`.
- Use structural table types and exported type aliases.
- Use type annotations and casts when inference is insufficient.
- Use if-expressions instead of `a and b or c` ternary idioms.
- Use generalized iteration for maps.
- Use numeric loops for arrays when order, holes, or explicit packed lengths matter.
- Use `table.clone`, `table.clear`, `table.create`, `table.move`, `table.freeze`, and explicit `table.unpack(args, 1, args.n)` according to their documented semantics.
- Use `time()` as the default runtime elapsed-time source.
- Use `os.clock()` for benchmarking/performance measurement.
- Use `os.time()` for Unix timestamps.
