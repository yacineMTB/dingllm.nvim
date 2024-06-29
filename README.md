### dingllm.nvim
Yacine's LLM nvim scripts


### Credits
This extension woudln't exist if it weren't for https://github.com/melbaldove/llm.nvim

I diff'd on a fork of it until it was basically a rewrite. Thanks @melbaldove!

The main difference is that I'm events, rather than a timed async loop. I noticed that on some versions of nvim, melbaldove's extension would deadlock my editor. I suspected nio, so I just replaced it with another dep.

### lazy config
```
coming soon!

```

### Documentation

Read the code. It's simple!

