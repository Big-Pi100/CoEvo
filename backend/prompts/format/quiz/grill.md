### 输出格式
最后一题回答完毕后，输出以下考核结果 JSON（不要其他文字）：

```json
{
  "task": "{task_name}",
  "passed": true,
  "correct": 3,
  "total": 4,
  "blind_spots": ["用户对XXX的理解有偏差"],
  "teaching_points": ["应重点讲解XXX和YYY的区别"]
}
```

- passed: correct/total >= 0.75 算通过
- blind_spots: 列出用户答错或理解模糊的具体概念
- teaching_points: 针对盲区应补充讲解的内容要点