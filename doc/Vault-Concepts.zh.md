# Vault 概念笔记

## 1. 单位系统

### Amount
- `amount` 表示某个具体 token 的数量。
- `amount0` 和 `amount1` 都是 token 最小单位下的原始数量。
- `amount` 不等于价值。

### Decimals
- `decimals` 定义了一个原始整数如何映射成一个完整 token 数量。
- 例如：
  - 18 位精度下，`1e18` 表示 1 个 token
  - 6 位精度下，`1e6` 表示 1 个 token

### Price
- `price` 表示 1 个完整 token 价值多少 base asset。
- 在这个项目里，`price` 使用 `1e18` 精度。

### Assets
- `assets` 表示统一换算成 base asset 后的标准化价值。
- `assets` 的作用是把不同 token 的余额转换到同一个单位里进行比较。
- `assets` 是“价值单位”，不是 token 数量单位。

### 最基础的价值换算公式
- 单个 token 的 base value 计算公式是：
  - `valueInBase = amount * price / 10**decimals`
- 含义是：
  - `amount` 是最小单位下的原始数量
  - `price` 是 1 个完整 token 的价格
  - `10**decimals` 用来把原始数量还原成“多少个完整 token”

### 例子
- 在 Solidity 里：
  - `1 ether` 只是一个语法糖，等于 `1e18`
  - 它表示的是一个 `uint256` 数值，不代表这个 token 一定是 ETH
- 所以如果某个 18 decimals 的 token 数量写成：
  - `2 ether`
  - 它的真实含义是：
  - `2e18`
  - 也就是“2 个完整 token”

- 如果：
  - `amount = 2e18`
  - `decimals = 18`
  - `price = 3e18`
- 那么：
  - `valueInBase = 2e18 * 3e18 / 1e18 = 6e18`
- 也就是：
  - 2 个 token
  - 每个值 3 个 base asset
  - 总价值是 6 个 base asset

再比如：
- 如果一个 6 decimals 的 token 数量是：
  - `20e6`
- 它的含义不是“二千万个 token”
- 而是：
  - `20 * 10**6`
  - 也就是“20 个完整 token”
- 如果它的价格是：
  - `1e18`
- 那它的 base value 就是：
  - `20e6 * 1e18 / 1e6 = 20e18`

### 关键规则
- `amount` = 有多少个 token
- `assets` = 值多少钱

## 2. 份额系统

### Meaning
- `shares` 表示用户对 vault 的所有权份额。
- 用户并不是直接拥有 vault 里的底层资产。
- 用户是通过 shares 按比例拥有整个 vault。

### totalSupply
- `totalSupply()` 表示总 shares 数量。
- 它不等于 `totalAssets()`。

### totalAssets
- `totalAssets()` 表示 vault 当前持有资产的总价值。
- 在当前实现里，它已经包含两部分：
  - vault 当前持有的 idle `token0/token1`
  - adapter 当前 deployed position 对应的底层 `amount0/amount1`
- 然后 vault 再用统一价格把这两部分一起估值。

### `totalAssets()` 的当前公式
- 当前实现的心智模型是：
  - `total0 = idle0 + deployed0`
  - `total1 = idle1 + deployed1`
- 然后：
  - `value0 = total0 * price0 / 10**decimals0`
  - `value1 = total1 * price1 / 10**decimals1`
  - `totalAssets = value0 + value1`

更紧凑地写就是：
- `totalAssets = valueInBase(idle0 + deployed0, price0, decimals0) + valueInBase(idle1 + deployed1, price1, decimals1)`

### 关键规则
- `shares` = 所有权单位
- `totalAssets` = vault 总价值
- `totalSupply` = 总份额数量

## 3. 核心流程

### Deposit
- `deposit` 的流程是：
  - `amount0/amount1 -> assetsToDeposit -> sharesToMint`
- vault 先把不同 token 的数量换算成统一价值。
- 然后根据当前 vault 定价计算应该 mint 多少 shares。

### Deposit 的份额公式
- 对已经初始化的 vault：
  - `sharesToMint = assetsToDeposit * totalShares / totalAssets`
- 对首次存款：
  - `sharesToMint = assetsToDeposit`

### Deposit 里的 `assetsToDeposit` 怎么算
- 当前实现里：
  - `value0 = amount0 * price0 / 10**decimals0`
  - `value1 = amount1 * price1 / 10**decimals1`
  - `assetsToDeposit = value0 + value1`

### 重要细节
- `deposit` 必须使用转账前的 `totalAssets`。
- 否则用户自己的存款会先被算进 vault，总价值分母变大，导致新用户拿到的 shares 偏少。

### Redeem
- `redeem` 的流程是：
  - `shares -> ownership ratio -> amount0Out/amount1Out`
- `redeem` 会按 shares 占比返还底层 token。
- 在当前最小集成里，`redeem` 还有一个额外前置条件：
  - 如果 adapter 里还有 active position
  - 就不能直接 `redeem`
  - 必须先把 deployed position withdraw 回 vault

### Redeem 的输出公式
- `amount0Out = vaultBalance0 * shares / totalSupplyBefore`
- `amount1Out = vaultBalance1 * shares / totalSupplyBefore`

### 当前 `redeem()` 要特别注意什么
- 当前实现里，`redeem()` 不是先把 shares 换算成一个统一的 `assets`，再去买回 token。
- 它当前做的是：
  - 按 shares 占总 shares 的比例
  - 直接拿走 vault 当前 idle token 余额中的同样比例
- 所以当前实现更准确地说是：
  - `amount0Out = vaultIdle0 * shares / totalSupplyBefore`
  - `amount1Out = vaultIdle1 * shares / totalSupplyBefore`
- 这也是为什么当前版本要求：
  - 如果 adapter 里还有 active position
  - 就要先 `withdrawFromVenue()`
  - 再 `redeem()`

### 重要细节
- `redeem` 必须使用 burn 前的 `totalSupply`。
- 当前版本下，如果资金仍然部署在 adapter 里，`redeem()` 会直接 revert `ActivePositionExists`。
- 所以当前真实流程是：
  - `deployToVenue(...)`
  - `withdrawFromVenue(...)`
  - `redeem(...)`

## 4. 约束与 Revert

### 为什么 Revert 很重要
- 智能合约正确性不只是 happy path 能跑通。
- 非法状态必须明确失败。

### 当前例子
- 零存款应该 revert。
- 非零资产但价格为 0 应该 revert。
- share 计算中的非法 vault 状态应该 revert。
- 非零存款如果最终 mint 出 0 shares，应该 revert。
- 用户赎回超过自己持有的 shares，应该 revert。

### 关键规则
- 业务输入检查通常属于 vault。
- 数学一致性检查可以属于 math library。

## 5. 测试分层

### VaultMath tests
- `VaultMath.t.sol` 测的是纯数学逻辑。
- 它直接验证公式和边界条件。

### Vault tests
- `Vault.t.sol` 测的是集成和业务流程。
- 它验证 vault 是否正确使用余额、价格、decimals 和 math library。

### 为什么两层测试都需要
- 数学本身可以是对的，但集成方式仍然可能是错的。
- 例如：
  - 价格传错
  - 余额取错
  - burn 了错误的单位
  - adapter 返回的是 amount，但 vault 当成 assets 去用

### 测试中的重复
- 场景准备的重复是正常的。
- 对同一个行为重复断言就没有那么有价值。
- 在当前阶段，保持显式、清晰的 setup，比过早抽 helper 更好。

## 6. 实例与类型名

### 什么时候用实例
- 当你要调用某个具体合约对象的函数或读取它的状态时，用实例。
- 例如：
  - `vault.deposit(...)`
  - `vault.redeem(...)`
  - `vault.totalAssets()`
  - `vault.balanceOf(alice)`

### 什么时候用类型名
- 当你要引用编译期的类型信息时，用类型名。
- 例如：
  - `AdaptiveLPVault.ZeroPrice.selector`
  - `AdaptiveLPVault.InsufficientShares.selector`
  - `VaultMath.InvalidPrice.selector`

### 关键规则
- 调用函数、读取状态：用实例
- 取 `selector`、error type、function selector：用类型名
- `address(vault)` 是地址值
- `AdaptiveLPVault` 是类型名

## 7. 这个项目里最容易混淆的几个量

### 1. `token0.balanceOf(address(vault))`
- 表示 vault 当前持有多少 `token0`。
- 单位是 `token0` 的原始数量。
- 它是 `totalAssets()` 的输入之一。
- 它也是 `redeem()` 计算 `amount0Out` 的基础。

### 2. `token1.balanceOf(address(vault))`
- 表示 vault 当前持有多少 `token1`。
- 单位是 `token1` 的原始数量。
- 它是 `totalAssets()` 的输入之一。
- 它也是 `redeem()` 计算 `amount1Out` 的基础。

### 3. `vault.totalAssets()`
- 表示 vault 当前底层资产的总价值。
- 单位是统一后的 base-denominated value，精度为 `1e18`。
- 它来自：
  - `token0.balanceOf(address(vault))`
  - `token1.balanceOf(address(vault))`
  - `price0`
  - `price1`
  - `VaultMath.getAssetsTotalValue(...)`
- 它是 vault 总价值，不是 shares。

### 4. `vault.totalSupply()`
- 表示 vault 当前总共发行了多少 shares。
- 单位是 shares。
- 它不是资产价值。
- 它会参与：
  - `deposit()` 的份额计算
  - `redeem()` 的比例计算

### 5. `vault.balanceOf(user)`
- 表示某个用户持有多少 shares。
- 单位是 shares。
- 它表示用户拥有 vault 的多少份额。
- 在 `redeem()` 里，用户最多只能赎回自己持有的 shares。

### 6. `vault.balanceOf(address(vault))`
- 表示 vault 合约自己这个地址持有多少 shares。
- 单位是 shares。
- 在当前设计里，这通常没有业务意义，而且一般是 `0`。
- 它不等于 `vault.totalAssets()`。

### 最核心的区分
- 底层资产层：
  - `token0.balanceOf(address(vault))`
  - `token1.balanceOf(address(vault))`
  - `vault.totalAssets()`
- 份额层：
  - `vault.totalSupply()`
  - `vault.balanceOf(alice)`
  - `vault.balanceOf(bob)`

### `amount0`、`vaultBalance0`、`amount0Out` 的区别
- `amount0`：某一次操作里的 `token0` 数量，通常是函数输入。
- `vaultBalance0`：vault 当前总共持有多少 `token0`，通常就是 `token0.balanceOf(address(vault))`。
- `amount0Out`：某次 `redeem()` 中，用户最终拿回的 `token0` 数量。

### 一个常见误区
- `token0.balanceOf(address(vault))` 不是 `amount0`。
- 更准确地说，`token0.balanceOf(address(vault))` 更像是 vault 当前的“总持仓量的一部分”。
- `amount0` 只是某一次 `deposit` 或某个局部场景中的 token0 数量。

### 什么时候它们可能相等
- 如果 vault 之前没有任何 `token0`，而且只发生了一次存款，那么：
  - `token0.balanceOf(address(vault)) == amount0`
- 但这只是某个时刻数值碰巧相等，不代表它们语义相同。

### 什么时候它们不相等
- 多次存款后，vault 当前持仓会是多次 `amount0` 的累计结果。
- 发生赎回后，vault 当前持仓也会变化。
- 所以大多数时候：
  - `token0.balanceOf(address(vault)) != amount0`

### 一个常见误解
- 错误理解：
  - `vault.totalAssets() == vault.balanceOf(address(vault))`
- 正确理解：
  - `vault.totalAssets()` 看的是底层资产总价值
  - `vault.balanceOf(address(vault))` 看的是 vault 自己持有多少 shares

### 另一个常见误解
- 错误理解：
  - `vault.totalAssets() == vault.balanceOf(alice) + vault.balanceOf(bob)`
- 更准确的理解：
- `vault.balanceOf(alice) + vault.balanceOf(bob)` 如果覆盖了全部用户，那等于 `vault.totalSupply()`
- `vault.totalAssets()` 只有在特殊情况下才会和 `totalSupply()` 数值碰巧相等
- 两者语义始终不同：一个是总价值，一个是总份额

### `redeem()` 里两个容易混的量
- `balanceOf(msg.sender)` 用来检查用户自己是否有足够 shares 可以赎回。
- `totalSupply()` 用来计算这次赎回占整个 vault 的比例。
- 一个用于权限/余额检查，一个用于比例计算，不能混用。

## 8. Solidity 语义补充

### 命名返回值
- 如果函数已经写了命名返回值，就应该直接给这些返回变量赋值。
- 不要在函数体里再声明同名局部变量。
- 否则容易出现：
  - 实际逻辑用的是局部变量
  - 最终返回的却还是默认值

### 例子
- 正确写法：
  - `amount0Out = ...;`
  - `amount1Out = ...;`
- 不推荐写法：
  - `uint256 amount0Out = ...;`
- `uint256 amount1Out = ...;`

## 9. Vault 与 Adapter 的边界

### Vault 和 Adapter 分别负责什么
- Vault 负责：
  - 接收用户存款
  - mint / burn shares
  - 维护 vault 级别的总资产和份额逻辑
  - 决定资产是 idle 还是 deployed
- Adapter 负责：
  - 按 vault 的指令与具体流动性场所交互
  - 执行 add/remove liquidity
  - 持有 venue position，例如当前 V2 版本里由 adapter 持有 LP token
  - 把 deployed position 换算成底层 token 数量

### 为什么当前 V2 Adapter 里的 `vault` 只是 `address`
- 在当前实现里，adapter 对 vault 的实际需求很少：
  - 比较 `msg.sender == vault`
  - 把 token 转回 `vault`
- 它不需要直接调用 `AdaptiveLPVault` 的业务函数。
- 所以在类型上写成 `address public immutable vault` 更合适。
- 这表示 adapter 依赖的是“被信任的调用方地址”，不是某个具体 vault 实现。
- 这不表示 vault 不重要，而是表示 adapter 当前不需要 vault 的完整业务接口。

### 这和接口依赖有什么关系
- 当前 [UniswapV2Adapter.sol](../contract/src/adapters/UniswapV2Adapter.sol) 显式实现了 [IVenueAdapter.sol](../contract/src/interfaces/IVenueAdapter.sol)。
- 这说明：
  - 上层模块依赖的是 adapter 的统一行为接口
  - adapter 不依赖某个具体 vault 实现类型
- 这是一种典型的低耦合设计：
  - vault 的“身份”用地址表达
  - adapter 的“职责”用接口表达

### 为什么 vault 里更适合存 `IVenueAdapter`，而不是 `UniswapV2Adapter`
- 如果 vault 里存的是：
  - `IVenueAdapter public adapter`
  - 含义是：vault 依赖的是 adapter 的统一能力
- 这些统一能力就是：
  - `addLiquidity`
  - `removeLiquidity`
  - `getPositionValue`
  - `hasPosition`
- 如果 vault 里存的是：
  - `UniswapV2Adapter public adapter`
  - 含义就变成：vault 依赖的是某个具体实现本身

更准确地说：
- `IVenueAdapter` 表达的是“只要你实现了这组行为，我就能和你协作”
- `UniswapV2Adapter` 表达的是“我认的是这个具体类型”

在当前架构里，vault 作为上层协调者，更应该关心：
- adapter 能不能部署资产
- 能不能撤回资产
- 能不能报告 deployed amounts

而不是关心：
- 它底层是不是 Uniswap V2
- 有没有 `pair`
- 有没有 `router`
- 内部实现细节是什么

这样设计的好处是：
- 以后如果换成 `UniswapV3Adapter`、`CurveAdapter` 或 mock adapter
- 只要它们实现同一个 `IVenueAdapter`
- vault 主体逻辑就不需要跟着改

你可以用一句话记住：
- 只需要“地址身份”时，用 `address`
- 只需要“统一行为”时，用 `interface`
- 只有真的依赖“具体实现细节”时，才用具体合约类型

所以在最小集成阶段：
- adapter 里把 `vault` 存成 `address`
- vault 里把 `adapter` 存成 `IVenueAdapter`
- 这是当前这套分层里最合理、也最稳定的依赖方向

### 为什么 `setAdapter(address _adapter)` 里会写 `adapter = IVenueAdapter(_adapter)`
- `address _adapter` 本身只是一个地址值。
- 单独的 `address` 类型只表示“某个链上地址”，不表示这个地址上有什么函数可以调用。
- 所以如果只是拿到一个 `address`，编译器并不知道你能不能对它调用：
  - `addLiquidity`
  - `removeLiquidity`
  - `getPositionValue`

当代码写成：
- `adapter = IVenueAdapter(_adapter);`

它的含义不是：
- 部署了一个新合约
- 创建了一个新对象
- 把地址“变成”了合约

它真正的含义是：
- 告诉 Solidity：请把这个地址当成一个“实现了 `IVenueAdapter` 接口的外部合约引用”来使用

这样后面才可以写：
- `adapter.addLiquidity(...)`
- `adapter.removeLiquidity(...)`
- `adapter.getPositionValue()`

更准确地说，这是：
- 一种“类型视角转换”
- 不是部署行为
- 也不是运行时自动校验

这一点很重要：
- `IVenueAdapter(_adapter)` 本身通常不会保证这个地址真的合法
- 如果这个地址不是正确的 adapter 合约
- 那么真正出问题的时间点，往往是在后续调用函数时

你可以把这三层区分清楚：
- `address _adapter`
  - 只是原始地址值
- `IVenueAdapter(_adapter)`
  - 把这个地址解释成一个可按接口调用的合约引用
- `IVenueAdapter public adapter`
  - 把这个接口引用保存到 vault 状态里，供后续调用

一句话记住：
- `address` 解决“它在哪”
- `interface` 解决“我能怎么调它”

### 现在这个版本的权限边界
- `addLiquidity()` 和 `removeLiquidity()` 是 `onlyVault`
- `getPositionValue()` 是公开 `view`
- `hasPosition()` 是公开 `view`
- `collectFees()` 当前版本固定 revert，因为 Uniswap V2 没有独立的 fee claim 步骤

### 当前 V2 Adapter 已经实现的输入约束
- constructor 会检查：
  - `vault`
  - `token0`
  - `token1`
  - `router`
  - `pair`
  这些地址都不能是零地址
- constructor 还会检查 `pair` 的 token 集合是否和配置一致
- 这里允许两种情况：
  - `pair.token0 == token0` 且 `pair.token1 == token1`
  - `pair.token0 == token1` 且 `pair.token1 == token0`
- 也就是说，当前实现不要求 pair 内部顺序和 adapter 输入顺序完全一致，只要求它们是同一组 token

### 当前 `params` 的语义
- `addLiquidity(amount0, amount1, params)` 虽然保留了 `params`
- 但当前最小实现里，`params` 必须为空
- 如果传入非空 `params`，会直接 revert `UnsupportedOperation`
- 这表示：
  - 接口为了以后扩展预留了位置
  - 但当前版本还没有引入额外的 venue-specific 参数

### 当前 adapter 的资产流
- `addLiquidity()` 时：
  - adapter 会先从 vault `safeTransferFrom` 拉取 `token0` 和 `token1`
  - 再授权 router
  - 再调用 router 执行加池
  - 剩余没用掉的 dust 会退回 vault
- `removeLiquidity()` 时：
  - adapter 会授权 router 使用 LP
  - router 拆池后，adapter 收到底层 token
  - adapter 再把底层 token 转回 vault
- 所以当前实现里：
  - vault 是资金来源和资金回收地
  - adapter 是 venue interaction executor
  - adapter 不是最终资产归属地

### 为什么 deploy 再 withdraw 不一定回到最初存入数量
- 当前最小集成阶段，重点是先验证两件事：
  - 钱是不是按预期从 vault 走到 adapter，又从 adapter 回到 vault
  - `totalAssets()` 的 idle + deployed 口径是不是一致
- 这不等于在验证：
  - 真实 AMM 价格变化
  - 滑点
  - 手续费收益
  - 无常损失
- 所以在当前 mock/integration tests 里：
  - withdraw 后拿回来的 `amount0Out/amount1Out`
  - 是由 mock router 预先设定的测试输出
  - 不是“必须等于最初存入数量”的协议承诺
- 更准确地说：
  - 当前阶段验证的是资金流闭环和 accounting 主干
  - 不是策略收益或真实市场结果

### 为什么 `deposit` 前用户要 `approve`，而 `deployToVenue` 里是 vault 自己 `approve adapter`
- 最简单的记法是：
  - 谁的钱，谁 `approve`

`deposit()` 时：
- token 还在用户手里
- vault 想把用户的 token 拉进 vault
- 但 vault 不能直接动用户的钱
- 所以必须先由用户自己点头：
  - `token.approve(vault, amount)`
- 然后 vault 才能在 `deposit()` 里执行：
  - `transferFrom(user, vault, amount)`

所以测试里在 `deposit()` 之前会先写：
- `token0.approve(address(vault), amount0)`
- `token1.approve(address(vault), amount1)`

这里不能把 `approve` 写进 `deposit()` 里自动完成，原因也很直接：
- `approve` 只能由 token 当前持有人来做
- `deposit()` 之前，token 的持有人是用户，不是 vault
- vault 没资格替用户授权自己花用户的钱

`deployToVenue()` 时：
- token 已经不在用户手里了
- token 已经在 vault 手里
- 接下来是 adapter 想从 vault 这里把 token 拉走去做加池
- 这时 token 的持有人是 vault
- 所以 vault 就可以自己授权 adapter：
  - `token.forceApprove(adapter, amount)`

然后 adapter 才能执行：
- `transferFrom(vault, adapter, amount)`

一句话对比：
- `deposit()`：用户的钱进 vault，所以用户先 `approve vault`
- `deployToVenue()`：vault 的钱进 adapter，所以 vault 自己 `approve adapter`

### `balanceOf`、`contract.function()`、`owner`、`msg.sender` 分别是什么意思
- 这几个词很容易被混在一起，但它们不是一回事。

最短记法：
- `xxx.balanceOf(yyy)`：问 `yyy` 持有多少 `xxx`
- `contract.function()`：调用这个合约
- `owner`：只有合约里专门定义了 `owner` 才有这个概念
- `msg.sender`：这次是谁在调用

#### 1. `xxx.balanceOf(yyy)` 在问什么
- 例如：
  - `pair.balanceOf(address(adapter))`
- 它的意思是：
  - 去问 `pair` 这个合约
  - `adapter` 这个地址现在持有多少 LP token
- 这里：
  - `pair` 是被查询的合约
  - `adapter` 是被查询余额的地址
- 它不是在说：
  - `pair` 是 owner
  - `adapter` 是 owner

#### 2. `contract.function()` 在表示什么
- 例如：
  - `adapter.addLiquidity(...)`
- 它的意思是：
  - 调用 `adapter` 这个合约上的函数
- 但真正决定权限是否通过的，不是“函数写在谁身上”，而是：
  - 这次调用的 `msg.sender` 是谁

#### 3. `owner` 不是每个合约天然都有
- `owner` 只有在合约自己专门定义了 owner 语义时才存在。
- 例如：
  - `AdaptiveLPVault` 继承了 `Ownable`
  - 所以它有 `owner()`
- 但像：
  - `pair.balanceOf(...)`
  - `adapter.addLiquidity(...)`
- 这些场景本身并不自动带有 “owner” 的概念

#### 4. `msg.sender` 才是这次真正的调用者
- 例如：
  - vault 调 `adapter.addLiquidity(...)`
- 对 adapter 来说：
  - `msg.sender = vault`
- 所以 adapter 的 `onlyVault` 检查才会通过
- 这时：
  - adapter 是被调用的合约
  - vault 才是这次调用的发起者

一句话区分：
- `balanceOf` 看的是“谁持有 token”
- `owner` 看的是“合约权限归谁管”
- `msg.sender` 看的是“这次是谁在调用”
- `contract.function()` 只是表示“函数写在哪个合约上”

### 为什么当前实现会把 approval 清零
- `addLiquidity()` 执行完后，会把 `token0/token1` 对 router 的 approval 清回 0
- `removeLiquidity()` 执行完后，会把 LP 对 router 的 approval 清回 0
- 这样做的意义是：
  - 减少长期悬挂授权
  - 降低后续误用或额外风险暴露
- 这不是 Uniswap V2 功能要求，而是当前实现选择的一种更保守的授权策略

### 为什么 `getPositionValue()` 不做 `onlyVault`
- 这个函数只读取公开链上状态：
  - adapter 当前 LP balance
  - pair reserves
  - pair total supply
  - pair token 顺序
- 它不移动资金，也不改变仓位。
- 即使把它限制成 `onlyVault`，外部观察者依然可以自己从链上把结果算出来。
- 所以这里的访问控制不会真正提供隐私或安全收益。
- 相反，公开 `view` 更利于：
  - 前端展示
  - keeper / monitor
  - 调试和脚本查询

### 当前 V2 Adapter 的一个重要理解点
- `getPositionValue()` 这个名字容易让人误以为它返回“oracle 价值”
- 但当前实现返回的是：
  - adapter 持有 LP token 所代表的底层 `amount0`
  - adapter 持有 LP token 所代表的底层 `amount1`
- 它不是统一计价后的 `assets`
- 所以不能把它直接当成 vault 的 `totalAssets()` 去参与份额计算，除非先做进一步定价转换。

### 为什么 `getPositionValue()` 还要处理 token 顺序映射
- pair 内部有自己的 `token0/token1` 顺序
- adapter 也有自己配置时传入的 `token0/token1` 语义
- 这两个顺序不一定一致
- 所以当前实现不是简单返回：
  - `reserve0 -> amount0`
  - `reserve1 -> amount1`
- 而是会先判断：
  - adapter 的 `token0` 是否等于 `pair.token0()`
- 如果不等于，就交换映射关系
- 这一点很重要，因为：
  - reserves 是 pair 视角
  - `amount0/amount1` 是 adapter 配置视角

### 当前事件应该怎么理解
- adapter 现在有 add/remove 事件
- 这些事件的作用主要是：
  - 方便链下观测
  - 方便之后接监控或索引
- 但在当前项目阶段，它们不是协议正确性的核心来源
- 当前更重要的是验证：
  - 实际 token balance 是否对
  - LP 持仓是否对
  - revert 条件是否对
  - position 换算是否对
- 所以当前测试里没有把 event assertion 当成核心测试内容

### 一个新的边界条件
- 当前 `UniswapV2Adapter` 增加了 `InvalidTotalSupply` 检查
- 含义是：
  - 如果 adapter 明明持有 LP balance
  - 但 pair 报告的 `totalSupply()` 却是 0
  - 这属于非法状态，应当显式 revert
- 这是 adapter 层的状态一致性检查，不是 vault 层的份额检查

### 当前 vault-adapter 最小集成已经做到什么
- vault 当前已经能：
  - 通过 `setAdapter(...)` 挂接一个 `IVenueAdapter`
  - 通过 `deployToVenue(...)` 把 idle 资金部署出去
  - 通过 `withdrawFromVenue(...)` 把 deployed 资金撤回
  - 通过 `totalAssets()` 把 idle balances 和 adapter reported amounts 一起估值
- 当前这版还没有做到：
  - 自动根据价格决定什么时候 deploy
  - 自动在 `redeem()` 里帮用户拆仓
  - 自动 rebalance
- 所以更准确地说：
  - 现在已经接通了 vault 和 adapter 的资产流主干
  - 但策略层和 oracle 层还没有接上

## 10. 我已经发现的常见错误

- 混淆 `amount`、`assets` 和 `shares`
- 混淆 `totalSupply()` 和 `totalAssets()`
- 在 `redeem` 检查里错误地用 `totalSupply` 代替 `balanceOf(msg.sender)`
- burn 了底层资产数量，而不是 burn shares
- 用 price 单位去期待 token 输出数量
- 把 adapter 的 `getPositionValue()` 误解成 vault 的 `totalAssets()`
- 把 adapter 需要信任的 vault 地址，误解成 adapter 必须依赖 `AdaptiveLPVault` 这个具体类型
- 看到两个量“数值刚好相等”就误以为它们“语义相同”
- 忽略 pair 视角和 adapter 视角的 token 顺序差异
- 把 `params` 当成当前版本已经可用的功能入口
- 只看 event 就以为已经验证了真实资产流

## 11. Uniswap V2 基础概念

### Pair
- `pair` 是池子本体合约。
- 它维护 `token0` 和 `token1` 的储备状态。
- 它也是 LP token 的发行者。
- 在 V2 里，真正装着资产、维护池子状态的是 `pair`，不是 `router`。
- 因为 `pair` 会 mint LP token，所以它本身也带有 ERC20 风格的能力，例如：
  - `balanceOf(address)`
  - `totalSupply()`
- 但在当前项目里，更适合把它理解成：
  - 一个池子合约
  - 同时也暴露出 LP token 相关函数
- 对 adapter 来说：
  - `pair.balanceOf(address(adapter))` 表示 adapter 持有多少 LP
  - 不是 pair 自己持有多少 LP

### Router
- `router` 是操作入口。
- 它帮助用户或 adapter 添加和移除流动性。
- `router` 不是池子本体，也不是最终持有储备的地方。
- 对 adapter 来说，`router` 主要解决的是“怎么执行 add/remove liquidity”。
- 更准确地说：
  - `router` 负责把你的输入组织成一次流动性操作
  - `pair` 负责最终的池子状态和份额关系

### Reserve
- `reserve0` 和 `reserve1` 表示 `pair` 当前记录的两种 token 储备量。
- 初学阶段可以先把它理解成：池子当前对应多少 `token0` 和多少 `token1`。
- 在 adapter 里，`reserve` 最重要的用途是把 LP 份额换算成底层 token 数量。
- `reserve` 是 pair 视角的数量，不是 vault 视角的数量。

### LP Token
- LP token 是对 `pair` 的份额凭证。
- 持有多少 LP token，就代表拥有这条池子的相应比例。
- 例如，如果 adapter 持有总 LP 供应量的 10%，那么它就拥有池子储备的 10%。
- 这里的“10%”指的是对池子底层储备的比例，不是对 vault 总份额 `shares` 的比例。

### V2 Position Value
- 在当前项目里，`getPositionValue()` 这个名字虽然叫 value，但当前返回的是底层 `amount0` 和 `amount1`。
- 它不是价格换算后的标准化资产价值。
- 在职责上：
  - adapter 负责返回底层 token 数量
  - vault 再负责结合价格把它们并入 `totalAssets()`
- 所以这里更准确的心智模型是：
  - adapter 返回的是 deployed token amounts
  - vault 负责把 idle amounts 和 deployed amounts 一起换算成 total assets
- 另外，当前实现还处理了 pair token 顺序可能与 adapter 配置顺序不同的问题。

### 为什么 adapter 同时需要 router 和 pair
- `router` 用来执行：
  - `addLiquidity`
  - `removeLiquidity`
- `pair` 用来读取状态：
  - reserves
  - LP 总供应量
  - 当前 LP 持仓对应的底层 token 数量
- 一句话：
  - `router` 负责操作
  - `pair` 负责池子状态和份额关系

### 为什么当前阶段不先引入 factory
- `factory` 的主要作用是：
  - 创建 pair
  - 根据 token 对查找 pair 地址
- 但在当前最小 adapter 阶段，我们已经把目标 pair 当作已知配置传入 constructor。
- 也就是说，现在我们只需要：
  - 对一个已知 pair 执行 add/remove liquidity
  - 读取这个已知 pair 的 reserves 和 LP 信息
- 当前阶段不需要：
  - 动态创建池子
  - 动态按 token 对查 pair
  - 管理多条 pair
- 所以先不引入 `factory`，是为了减少复杂度，而不是因为它不重要。

### 当前测试重点为什么不是 event
- 在当前阶段，`V2Adapter.t.sol` 的重点是：
  - 权限
  - revert 分支
  - 资产流
  - LP 持仓
  - position 换算
- event 测试不是完全没价值
- 但只要还没有下游系统强依赖固定 event schema，它的优先级就低于状态和余额测试
- 你可以把它理解成：
  - event 测试更偏“观测接口测试”
  - balance / position / revert 测试更偏“协议行为测试”

## 12. ERC20、IERC20、SafeERC20 的区别

### ERC20
- `ERC20` 是代币的实现。
- 当你想自己发行一个 token，或者自己实现一个 share token 时，用 `ERC20`。
- 例如：
  - `AdaptiveLPVault is ERC20`
  - `MockERC20 is ERC20`

### IERC20
- `IERC20` 是代币接口。
- 当你只是想和一个外部已有 token 交互时，用 `IERC20`。
- 它只声明函数，不实现逻辑。
- 例如：
  - `IERC20 token0`
  - `IERC20 token1`
- 它表达的是“我关心这个对象能不能按 ERC20 被调用”，不是“我关心它的完整实现”。

### SafeERC20
- `SafeERC20` 是安全调用 ERC20 的工具库。
- 它不是 token，也不是接口。
- 它的作用是更稳地调用：
  - `transfer`
  - `transferFrom`
  - `approve`
- 典型搭配是：
  - `using SafeERC20 for IERC20`

### 在当前项目里怎么理解
- `ERC20`：我自己要发 token
- `IERC20`：我要调用外部已有 token
- `SafeERC20`：我要安全地转外部 token
- 三者不是同一层概念，不能混着理解。

### 为什么 `IUniswapV2Pair` 不需要 import `ERC20`
- 因为 `IUniswapV2Pair` 是接口，不是实现。
- 它只需要声明外部合约有哪些函数可以调用。
- 即使 pair 本身会 mint LP token，也不代表接口文件要继承 `ERC20` 实现。

### 为什么 `IUniswapV2Pair` 里可以直接写 `balanceOf` 和 `totalSupply`
- 因为 pair 本身也是 LP token 的发行者，所以它确实具有 ERC20 风格的函数。
- 在当前项目里，把这些函数直接写进 `IUniswapV2Pair` 更符合 adapter 的使用方式。
- 这样后面可以直接写：
  - `pair.balanceOf(address(this))`
  - `pair.totalSupply()`
- 不需要在 adapter 里反复做：
  - `IERC20(address(pair)).balanceOf(...)`
  - `IERC20(address(pair)).totalSupply()`
- 这不代表 `pair` 在概念上等于普通 ERC20，而是代表它暴露了 adapter 当前需要的那部分 ERC20 风格接口。

## 13. 我当前的心智模型

- `amount` = token 数量
- `assets` = 标准化后的统一价值
- `shares` = vault 所有权份额

- `deposit` = token 进来，shares 出去
- `redeem` = shares 进来，token 出去

- `totalAssets` = vault 当前总价值
- `totalSupply` = vault 当前总 shares

- `totalAssets` 和 `totalSupply` 在初始化阶段可能数值相等
- 但它们语义始终不同：一个表示总价值，一个表示总份额

- `pair LP` = 对某条流动性池子的份额
- `vault shares` = 对整个 vault 的份额
- 这两种“份额”都叫份额，但属于完全不同的系统，不能混用
