# CoEvo Chat 页面回归问题深度调查报告

> **调查日期**：2026-05-15  
> **问题触发**：修复 BIG-1~BIG-5 后本地测试 Chat 功能出现回归  
> **现象**：历史加载不稳定、新建会话灰屏、消息不显示、多次测试后完全灰屏

---

## TL;DR

**三个独立问题叠加导致 Chat 页面瘫痪：**

1. **`_isInitializing` 永不解除**：`_init()` 无 try-catch，任一异步操作失败 → `_isInitializing` 永为 `true` → ChatSkeleton 永驻（灰屏）
2. **AnimatedList + KeyedSubtree 状态丢失**：`_listSeed` 变化时重建子树，`_listKey.currentState` 在过渡期变 null → `_addMessage()` 静默丢弃消息
3. **`getConversationTurns()` 无错误处理**：唯一致命 API 方法缺少 try-catch，网络故障直接炸穿 `_init()`

---

## 一、问题 1：ChatSkeleton 灰屏（_isInitializing 卡死）

### 1.1 根因

`_init()` 方法在 BIG-4 修复后仍**完全没有 try-catch**：

```dart
// chat_screen.dart:68
Future<void> _init() async {
    // ... auth retry ...

    _client = ChatClient(...);

    final planFuture = _loadPlan();
    final subFuture = _checkSubscription();

    final history = await _client!.getConversationTurns(_convId);  // ⚠️ 可抛异常！
    // ... 处理历史 ...

    await planFuture;
    await subFuture;

    if (mounted) setState(() => _isInitializing = false);  // ← 永远到不了！
}
```

**崩溃路径**：

```
getConversationTurns() 抛出异常（网络/超时）
    → _init() 无 catch，异常逃逸
    → _isInitializing 保持 true
    → build() 中 _isInitializing ? ChatSkeleton() : ...
    → 用户看到永久脉冲灰块
```

### 1.2 为什么 `getConversationTurns()` 会抛异常

```dart
// chat_client.dart:229 — 唯一没有 try-catch 的 API 方法！
Future<List<Map<String, dynamic>>> getConversationTurns(String convId) async {
    final resp = await http.get(uri, headers: _authHeaders)
        .timeout(ApiConfig.requestTimeout);        // ← TimeoutException!
    // ...                                            ← 网络错误也直接抛出！
}
```

对比其他 API 方法都有 try-catch：
- `getPlans()` → try-catch → 返回 `[]`
- `getPreferences()` → try-catch → 返回 `{}`
- `getConversationTurns()` → **无 try-catch** → 抛出原始异常

### 1.3 触发条件

| 场景 | 是否触发 |
|------|---------|
| 后端未启动 / 8080 端口不可达 | ✅ 灰屏 |
| 网络波动导致 HTTP 超时（10s） | ✅ 灰屏 |
| 后端返回 401（BIG-5 鉴权失败） | ❌ 返回 `[]`（非 200 走 `return []`） |
| 后端正常，历史为空 | ❌ 正常显示欢迎消息 |

---

## 二、问题 2：AnimatedList 消息丢失（渲染空白）

### 2.1 根因

`_addMessage()` 通过 `GlobalKey` 获取 AnimatedListState：

```dart
// chat_screen.dart:352
void _addMessage(Message msg) {
    _messages.add(msg);
    _listKey.currentState?.insertItem(_messages.length - 1, ...);  // ← ? 静默丢弃！
}
```

当 `_listKey.currentState` 为 null 时，消息被静默丢弃——数据在 `_messages` 列表中，但从不渲染到 UI。

### 2.2 currentState 何时为 null

**场景 A：新会话按钮**

```dart
onPressed: () {
    _listSeed++;                // ① 触发 KeyedSubtree 重建
    setState(() {
        _messages.clear();      // ② 清空消息
    });
    // ...
    _addMessage(welcomeMsg);    // ③ 此时 setState 已调度但未执行！
                                 //    KeyedSubtree 即将重建，
                                 //    AnimatedList 即将被卸载 → currentState = null
                                 //    insertItem 静默丢弃！
}
```

时序问题：
```
t0: _listSeed++    (标记需要重建)
t1: setState()     (调度 rebuild)
t2: _addMessage()  (currentState 可能已失效)
t3: build() 执行   (KeyedSubtree 重建，AnimatedList 重新挂载)
```

在 t2 时刻，AnimatedList 正准备被 KeyedSubtree 重建卸载，`currentState` 为 null。消息进入 `_messages` 列表但从未渲染。

**场景 B：历史列表切换到其他对话**

```dart
onPressed: () async {
    _listSeed++;                // ①
    // ...
    final history = await _client!.getConversationTurns(_convId);
    setState(() {               // ②
        _messages.clear();
        for (final turn in history) {
            _messages.add(...);  // ③ 直接加到列表，不走 _addMessage
        }
    });
}
```

这里使用 `setState` 直接添加而非 `_addMessage().insertItem()`。但 `initialItemCount: _messages.length` 在 AnimatedList 构造时只执行一次。如果 history 异步加载后消息数量超过初始值，AnimatedList 不知道有新 item。**应该用 `_addMessage()` 而非直接 `_messages.add()`**。

### 2.3 为什么间歇性出现

- 如果 API 响应快（缓存命中、数据量小），`addMessage` 在 rebuild 前完成 → 正常
- 如果 API 响应慢，`addMessage` 在 rebuild 期间执行 → 消息丢失
- 竞态条件，难以稳定复现

---

## 三、问题 3：消息发送后无回复

### 3.1 根因

发送消息时的竞态链：

```dart
// _sendMessage()
_addMessage(userMsg);          // 可能被静默丢弃（currentState=null）
setState(() => _isWaiting = true);

if (_session == null) {
    _session = _client!.streamChat(text);
    _sessionSub = _session!.events.listen(
        (event) => _handleWsEvent(event),  // ← 异步接收 WS 事件
    );
    _addMessage(aiBubble);      // 可也能被静默丢弃
    _streamingIndex = _messages.length - 1;
}
```

如果 `_addMessage(aiBubble)` 被丢弃，`_streamingIndex` 指向一个不存在于 AnimatedList 中的位置。后续 `_updateStreaming()` 和 `_finalizeStreaming()` 中的 `setState` 更新一个不可见的元素，用户看不到任何回复。

### 3.2 完整崩溃链

```
用户输入"你好" 
  → _sendMessage()
  → _addMessage(userMsg)           // currentState=null → 静默丢弃
  → WS 连接正常
  → _addMessage(aiBubble)          // currentState=null → 静默丢弃  
  → _streamingIndex = 3            // 指向不可见元素
  → WS 返回 token/done 事件
  → _updateStreaming / _finalizeStreaming 更新 _messages[3]
  → AnimatedList 不知道 index 3 存在 → 不渲染
  → 用户看到空白（没有任何消息气泡）
```

---

## 四、问题 4：多次测试后彻底灰屏

### 4.1 根因

这是**状态累积污染**。ChatScreen 使用 `ShellRoute`，页面状态在 Tab 切换间保持：

```
用户操作序列：
  1. 启动 App → Chat 页 _init() → 正常（网络好）
  2. 发送消息 → _addMessage 偶尔丢失
  3. 切换 Tab → ChatScreen 状态保持
  4. 切回 Chat → 继续使用旧状态
  5. 点"新对话" → _listSeed++ → KeyedSubtree 重建 → _addMessage 丢失
  6. "新对话"的 _loadPlan() 后台运行 → 可能影响后续
  7. 网络抖动 → getConversationTurns 抛异常 → _isInitializing 永不解除
  8. 灰屏 → 即使切 Tab 再回来，还是灰屏（_isInitializing 仍为 true）
```

每次操作都可能留下一个"僵尸状态"：`_isInitializing=true`、`_streamingIndex` 指向无效位置、`_session` 引用过期连接。累积到一定程度后，整个 ChatScreen 无法恢复。

---

## 五、完整问题矩阵

| 编号 | 严重度 | 问题 | 文件:行 | 触发条件 |
|------|--------|------|---------|---------|
| **R1** | 🔴 P0 | `_init()` 无 try-catch，async 异常致 `_isInitializing` 永不解除 | `chat_screen:68` | 网络故障 / API 超时 |
| **R2** | 🔴 P0 | `getConversationTurns()` 无 try-catch | `chat_client:229` | 网络故障 |
| **R3** | 🔴 P0 | `_addMessage` 在 KeyedSubtree 过渡期静默丢弃 | `chat_screen:352` | 新会话 / 切换对话 |
| **R4** | 🔴 P0 | 新会话 `_listSeed++` + `_addMessage` 竞态 | `chat_screen:806-827` | 点"新对话" |
| **R5** | 🟡 P1 | 对话切换直接 `_messages.add()` 不走 AnimatedList 插入 | `chat_screen:776-793` | 切换历史对话 |
| **R6** | 🟡 P1 | `_sendMessage` 的 `_addMessage` 可能在列表重建期间执行 | `chat_screen:359-421` | 发送消息 |
| **R7** | 🟡 P1 | `_isWaiting` 在 `_finalizeStreaming` 中设为 false，但 WS 异常时可能不被调用 | `chat_screen:499-515` | WS 异常断开 |

---

## 六、修复方案

### 6.1 紧急修复：_init() 加 try-catch + getConversationTurns 加错误处理

```dart
// chat_screen.dart _init()
Future<void> _init() async {
    try {
        // ... auth retry ...
        _client = ChatClient(...);

        final planFuture = _loadPlan();
        final subFuture = _checkSubscription();

        try {
            final history = await _client!.getConversationTurns(_convId);
            // ... 处理历史 ...
        } catch (e) {
            debugPrint('_init: history load failed: $e');
            // 降级：显示欢迎消息
            if (mounted) setState(() {
                _messages.add(Message(
                    role: 'assistant',
                    content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
                    timestamp: DateTime.now(),
                ));
            });
        }

        await planFuture;
        await subFuture;
    } catch (e) {
        debugPrint('_init: fatal error: $e');
    } finally {
        if (mounted) setState(() => _isInitializing = false);  // ← 无论如何都要设置！
    }
}
```

```dart
// chat_client.dart getConversationTurns
Future<List<Map<String, dynamic>>> getConversationTurns(String convId) async {
    try {                                                    // ← 新增
        final resp = await http.get(uri, headers: _authHeaders)
            .timeout(ApiConfig.requestTimeout);
        if (resp.statusCode != 200) return [];
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return (data['turns'] as List<dynamic>?)
            ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
    } catch (e) {
        debugPrint('getConversationTurns error: $e');
        return [];
    }
}
```

### 6.2 核心修复：移除 KeyedSubtree + 修复 _addMessage

**问题本质**：`KeyedSubtree` + `AnimatedList` + `GlobalKey` 组合在对话切换时产生竞态窗口，`currentState` 间歇为 null。

**方案**：取消 KeyedSubtree 包装，改用 `didUpdateWidget` 检测对话切换并重建列表：

```dart
// 删除 _listSeed 变量
// 删除 KeyedSubtree 包装
// 改用 convId 变化检测

@override
void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.conversationId != null && 
        widget.conversationId != oldWidget.conversationId) {
        _switchConversation(widget.conversationId!);
    }
}
```

```dart
// build() 中直接使用 AnimatedList
Expanded(
    child: _isInitializing
        ? const ChatSkeleton()
        : AnimatedList(
            key: _listKey,
            controller: _scrollController,
            initialItemCount: _messages.length,
            ...
          ),
),
```

**同时修复 `_addMessage` 添加重试机制**：

```dart
void _addMessage(Message msg) {
    _messages.add(msg);
    final idx = _messages.length - 1;
    if (_listKey.currentState != null) {
        _listKey.currentState!.insertItem(idx, 
            duration: const Duration(milliseconds: 300));
    } else {
        // 延迟重试：等待 widget 重建完成
        WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_listKey.currentState != null) {
                _listKey.currentState!.insertItem(idx,
                    duration: const Duration(milliseconds: 300));
            } else {
                // 最终降级：强制 setState 触发重建
                debugPrint('_addMessage: currentState still null, forcing rebuild');
                setState(() {});
            }
        });
    }
    Future.delayed(const Duration(milliseconds: 50), _scrollToBottom);
}
```

### 6.3 新对话按钮修复

```dart
onPressed: () {
    _sessionSub?.cancel();
    _session = null;
    final newConvId = 'conv_${DateTime.now().millisecondsSinceEpoch}';
    
    ref.read(currentConversationIdProvider.notifier).state = newConvId;
    
    setState(() {
        _messages.clear();
        _convId = newConvId;
        _activePlan = null;
        _isInitializing = false;   // 确保不显示骨架屏
    });
    
    _client = ChatClient(
        userId: ref.read(authProvider).userId ?? 'default_user',
        conversationId: newConvId,
        token: ref.read(authProvider).token,
    );
    
    _loadPlan();
    
    // 延迟添加欢迎消息，确保 AnimatedList 已重建
    WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
            _addMessage(Message(
                role: 'assistant',
                content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
                timestamp: DateTime.now(),
            ));
        }
    });
},
```

### 6.4 对话切换修复

```dart
// 从历史列表切换对话
onPressed: () async {
    final result = await context.push<String>('/conversations');
    if (result != null && mounted) {
        _sessionSub?.cancel();
        _session = null;
        _convId = result;
        _activePlan = null;
        ref.read(currentConversationIdProvider.notifier).state = _convId;
        _client = ChatClient(...);

        setState(() {
            _messages.clear();
            _isInitializing = true;
        });

        _loadPlan();

        try {
            final history = await _client!.getConversationTurns(_convId);
            if (mounted) setState(() {
                if (history.isNotEmpty) {
                    for (final turn in history) {
                        _messages.add(Message(
                            role: turn['role'] as String? ?? 'assistant',
                            content: turn['content'] as String? ?? '',
                            timestamp: DateTime.now(),
                        ));
                    }
                } else {
                    _messages.add(Message(
                        role: 'assistant',
                        content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
                        timestamp: DateTime.now(),
                    ));
                }
                _isInitializing = false;
            });
        } catch (e) {
            debugPrint('Conversation switch: history load failed: $e');
            if (mounted) setState(() {
                _messages.add(Message(
                    role: 'assistant',
                    content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
                    timestamp: DateTime.now(),
                ));
                _isInitializing = false;
            });
        }
    }
},
```

---

## 七、修复优先级

| 优先级 | 修复项 | 影响范围 | 工作量 |
|--------|--------|---------|--------|
| **立即** | `_init()` 加 try-catch + `finally` 设置 `_isInitializing=false` | 阻止灰屏 | 5 行 |
| **立即** | `getConversationTurns()` 加 try-catch | 阻止灰屏 | 3 行 |
| **高** | `_addMessage()` 加 postFrameCallback 重试 | 消息不丢失 | 10 行 |
| **高** | 移除 KeyedSubtree 包装 | 消除竞态根因 | 30 行 |
| **高** | 新对话/切换对话 加 `_isInitializing` 显式管理 | 切换稳定 | 20 行 |
| **中** | 对话切换改用 `_addMessage()` 而非直接 `_messages.add()` | AnimatedList 同步 | 10 行 |

---

*报告版本: V1.0*  
*调查者: 齐活林 (Delivery Director)*  
*调查工具: 静态代码分析 + 数据流时序追踪*
