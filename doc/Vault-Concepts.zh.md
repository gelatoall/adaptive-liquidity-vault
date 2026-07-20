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
- 当前 vault 明确把配置的 `token0` 作为 base asset：
  - `price0 = 1e18`，表示 1 个完整 token0 值 1 个 token0
  - `price1` 表示 1 个完整 token1 值多少 token0
- 因此 `price0` 和 `price1` 使用同一个计价单位，可以相加各自换算后的价值。

### Assets
- `assets` 表示统一换算成 base asset 后的标准化价值。
- `assets` 的作用是把不同 token 的余额转换到同一个单位里进行比较。
- `assets` 是“价值单位”，不是 token 数量单位。

### TWAP
- `TWAP` 是 `Time-Weighted Average Price`，中文可以理解为“时间加权平均价格”。
- 它不是读取某一瞬间的价格，而是用一段时间内的累计价格变化计算平均价格。
- 直觉上：
  - spot price 是“现在这一刻的价格”
  - TWAP 是“一段时间内的平均价格”
- 在 AMM 里，瞬时 reserve / spot price 可能被一次大额 swap 或 flash loan 短暂扭曲。
- TWAP 通过拉长观察窗口，降低短时间价格操纵对 oracle 的影响。
- 代价是：
  - 价格反应更慢
  - 必须等待足够的时间窗口
  - 不适合表达瞬时市场价格

### Volatility
- `volatility` 可以理解为“价格变化有多剧烈”。
- 在严格金融学里，volatility 往往会用历史收益率、标准差、年化等方式计算。
- 当前项目里的最小实现没有做完整统计模型，而是先用“最近两次价格快照之间的变化幅度”代理 volatility。
- 例子：
  - 价格从 `100` 变到 `101`，变化是 `1%`
  - 价格从 `100` 变到 `120`，变化是 `20%`
  - 第二种情况就被认为波动更高
- 项目里统一用 `bps` 表示比例：
  - `10_000 bps = 100%`
  - `1_000 bps = 10%`
  - `100 bps = 1%`
- `VolatilityBucketStrategy` 不关心 volatility 是怎么计算出来的，只关心 `IVolatilityOracle.getVolatilityBps()` 返回的数字。
- `bucket` 可以理解为“分档”或“区间”。
- 把连续的 volatility 数字分到几个 bucket 里，可以避免为每一个具体数值都单独配置策略。
- 这个数字会被映射到三个 bucket：
  - `LOW`：低波动
  - `MEDIUM`：中等波动
  - `HIGH`：高波动
- 每个 bucket 可以配置不同的 venue 权重。
  - 低波动时可以偏向更集中的 LP 策略
  - 高波动时可以偏向更保守或更分散的 LP 策略
  - 当前代码只实现“根据 bucket 选择不同权重表”，不负责判断这些权重是否经济上最优

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
- 然后 vault 再通过 `IPriceOracle` 提供的价格把这两部分一起估值。

### `totalAssets()` 的当前公式
- 当前实现的心智模型是：
  - `total0 = idle0 + deployed0`
  - `total1 = idle1 + deployed1`
- 然后：
  - `value0 = total0 * price0 / 10**decimals0`
  - `value1 = total1 * price1 / 10**decimals1`
  - `totalAssets = value0 + value1`
- 这里的 `price0` 和 `price1` 不是 vault 自己存的状态变量，而是通过 `oracle.getPrices()` 读出来的。
- 两个价格必须使用同一个 base；当前实现统一使用 vault `token0`，所以 `totalAssets()` 的返回值也以 token0 计价。

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
- 当前签名是 `deposit(amount0, amount1, receiver)`。
- `msg.sender` 提供 `token0/token1`，`receiver` 接收新 mint 出来的 vault shares。
- 所以 caller 和 receiver 可以不同：
  - Alice 可以出 token
  - Bob 可以收到 shares

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
- 当 vault 处于 paused 状态时，`deposit` 会被禁止，因为暂停状态下不应该继续接受新资金。

### Redeem
- `redeem` 的流程是：
  - `shares -> ownership ratio -> amount0Out/amount1Out`
- `redeem` 会按 shares 占比返还底层 token。
- 当前签名是 `redeem(shares, receiver, owner, withdrawalParams)`。
- `owner` 是 shares 被 burn 的地址。
- `receiver` 是最终收到 `token0/token1` 的地址。
- `msg.sender` 是发起 redeem 的地址。
- 如果 `msg.sender != owner`，则 `msg.sender` 必须先获得 `owner` 对 vault shares 的 ERC20 allowance。
- 在当前集成里，`redeem` 会同时处理：
  - vault 里直接持有的 idle token
  - 已注册 venue 里按 vault 记账追踪的 deployed liquidity

### Redeem 的输出公式
- `idle0Out = vaultIdle0 * shares / totalSupplyBefore`
- `idle1Out = vaultIdle1 * shares / totalSupplyBefore`
- `venueLiquidityToWithdraw = venueLiquidity * shares / totalSupplyBefore`
- 最终输出是 idle 部分加上所有 venue 撤仓返回的 token。

### 当前 `redeem()` 要特别注意什么
- 当前实现里，`redeem()` 不是先把 shares 换算成一个统一的 `assets`，再去买回 token。
- 它当前做的是：
  - 按 shares 占总 shares 的比例
  - 直接拿走 vault 当前 idle token 余额中的同样比例
  - 同时从每个 active venue 中撤出相同比例的 tracked liquidity
- 所以当前实现更准确地说是：
  - `amount0Out = idle0Out + venue0Out`
  - `amount1Out = idle1Out + venue1Out`
- 如果 `shares == totalSupplyBefore`，会直接撤出每个 active venue 的全部 tracked liquidity，避免整数除法留下 dust。
- 如果用户部分赎回的 shares 相对总 shares 太小，`venueLiquidity * shares / totalSupplyBefore` 可能会因为整数除法向下取整变成 0。此时 vault 会 revert `RedeemAmountTooSmall`，避免用户 shares 被 burn 但拿不到 deployed liquidity 对应资产。
- `redeem` 现在接收 `withdrawalParams`，可以按 `venueId` 给不同 venue 的 withdrawal 传入不同的 slippage/deadline 参数。
- 如果某个 active venue 没有对应的 `withdrawalParams`，vault 会向该 adapter 传空 `params`，adapter 使用自己的默认值。

### 重要细节
- `redeem` 必须使用 burn 前的 `totalSupply`。
- 当前版本下，如果资金仍然部署在任意 venue 里，`redeem()` 会按 shares 比例调用内部 withdrawal flow，把用户对应比例的 liquidity 撤回后再转出 token。
- `ActivePositionExists` 仍用于保护 `setVenue(...)`：有 active liquidity 时不能替换对应 venue adapter。
- `redeem` 不受 paused 状态限制。这样在紧急情况下，即使 owner 暂停了正常运营，用户仍然可以退出。

### Pause / Emergency Exit
- `pause()` 是 owner 控制的安全开关。
- paused 后会禁止正常运营动作：
  - `deposit`
  - `deployToVenue`
  - `rebalance`
  - `rebalanceWithStrategy`
- paused 后仍然允许退出相关动作：
  - `redeem`
  - `withdrawFromVenue`
  - `emergencyExit`

`emergencyExit(withdrawalParams)` 的作用是：
- 遍历所有 registered venue
- 把有 tracked liquidity 的 active position 全部撤回 vault idle balance
- 然后暂停 vault

它和普通 `rebalance` 的区别是：
- `rebalance` 是正常运营，用来调整资产分配
- `emergencyExit` 是应急路径，只负责把资金从 venue 拉回 idle 并暂停

### Oracle Circuit Breaker
- `checkSystemHealth()` 是给 keeper / monitoring 看的健康状态接口。
- 当前返回三种状态：
  - `NORMAL`：vault 没暂停，并且当前启用的 oracle 健康要求都满足
  - `ORACLE_STALE`：当前最小实现里，表示启用了 oracle health check，但还没有配置 `volatilityOracle`
  - `PAUSED`：vault 已暂停
- `setOracleHealthCheckEnabled(true)` 后，`rebalanceWithStrategy(...)` 会要求 vault 已经配置 `volatilityOracle`。
- 这一步的意义是：
  - 防止策略 rebalance 在缺少关键 volatility oracle 的情况下继续执行
  - 给后续 keeper 判断 `canRebalance` / `checkSystemHealth` 留出稳定接口
- 当前还没有实现完整的 timestamp stale 检测。
- 也就是说，现在的 `ORACLE_STALE` 更准确地说是“必须依赖的 oracle 未配置或不可用”，不是已经读取 oracle 时间戳后判断过期。
- `emergencyExit` 不应该被 `whenNotPaused` 限制，因为 vault 已经 paused 时也可能还需要继续尝试撤仓

### Keeper 执行权限
- 当前 vault 支持配置一个 `keeper` 地址。
- `keeper` 的职责很窄：只能触发已经配置好的 `rebalanceWithStrategy(data, withdrawalParams)`。
- `keeper` 不能配置：
  - oracle
  - strategy
  - venue
  - pause / unpause
  - emergencyExit
  - manual `rebalance(targets, withdrawalParams)`
  - manual `deployToVenue` / `withdrawFromVenue`
- 这样设计的原因是把“配置权”和“执行权”拆开：
  - `owner` 负责治理和系统配置
  - `keeper` 负责按当前策略触发执行
- 这不是完整 autonomous keeper 系统。当前还没有实现 keeper reward、Gelato/Chainlink resolver、自动生成 withdrawal params，或者链上激励结算。

### canRebalance / Recommended Targets
- `canRebalanceWithStrategy()` 是 vault 层的只读预检查。
- 它回答的是：“现在调用 `rebalanceWithStrategy(...)` 会不会被 vault 自己的 guard 拦住？”
- 它会检查：
  - strategy 是否配置
  - vault 是否 paused
  - cooldown 是否结束
  - gas price 是否超过上限
  - 需要 volatility oracle 时是否已配置
  - volatility delta 是否达到阈值
- 它不会调用 `strategy.buildTargets(...)`。
- 所以它不保证 strategy 一定能成功生成 plan，也不保证 adapter 执行一定成功。
- `VolatilityBucketStrategy.getRecommendedTargets()` 是 strategy 层的推荐结果。
- 因为当前项目不是单一 venue 模型，而是多 venue 权重模型，所以返回的是 `TargetConfig[]`，包含 `venueId + weightBps + params`。
- 这相当于 guidance 里 `getRecommendedVenue()` 的多 venue 版本。

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
- paused 状态下调用 `deposit`、`deployToVenue`、`rebalance`、`rebalanceWithStrategy` 应该 revert。
- 非 owner 调用 `pause`、`unpause`、`emergencyExit` 或资本管理函数应该 revert。
- vault constructor 配置零地址、相同的 `token0/token1`，或零 decimals 时应该 revert。

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
  - `oracle.getPrices()`
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
  - `mapping(uint256 => VenueConfig) public venues`
  - 其中 `VenueConfig.adapter` 是 `IVenueAdapter`
  - 含义是：vault 依赖的是每个 venue adapter 的统一能力
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
- vault 里按 `venueId` 把 `adapter` 存成 `IVenueAdapter`
- 这是当前这套分层里最合理、也最稳定的依赖方向

### 为什么 `setVenue(..., address _adapter, ...)` 里会写 `adapter: IVenueAdapter(_adapter)`
- `address _adapter` 本身只是一个地址值。
- 单独的 `address` 类型只表示“某个链上地址”，不表示这个地址上有什么函数可以调用。
- 所以如果只是拿到一个 `address`，编译器并不知道你能不能对它调用：
  - `addLiquidity`
  - `removeLiquidity`
  - `getPositionValue`

当代码写成：
- `adapter: IVenueAdapter(_adapter)`

它的含义不是：
- 部署了一个新合约
- 创建了一个新对象
- 把地址“变成”了合约

它真正的含义是：
- 告诉 Solidity：请把这个地址当成一个“实现了 `IVenueAdapter` 接口的外部合约引用”来使用

这样后面才可以写：
- `venues[venueId].adapter.addLiquidity(...)`
- `venues[venueId].adapter.removeLiquidity(...)`
- `venues[venueId].adapter.getPositionValue()`

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
- `venues[venueId].adapter`
  - 把这个接口引用保存到指定 venue 的配置里，供后续调用

一句话记住：
- `address` 解决“它在哪”
- `interface` 解决“我能怎么调它”

### 为什么 `IPriceOracle` 里不写 `setPrices`
- `IPriceOracle` 的职责是定义“vault 怎么取价”，不是定义“oracle 怎么更新价格”。
- 所以这个接口只需要暴露：
  - `getPrices()`
- `setPrices()` 属于具体实现的可变状态接口，不属于所有 oracle 都必须具备的统一能力。
- 例如：
  - `MockPriceOracle` 需要 `setPrices()`，因为测试里要手动控制价格
  - `TWAP` 实现不应该有 `setPrices()`，因为它的价格来自链上历史数据和时间窗口，不是手工写入
- 也就是说：
  - `IPriceOracle` 负责“消费端统一读价”
  - `MockPriceOracle` 负责“测试时可写价”
  - `TWAP` 负责“生产环境自动出价”

### 现在这个版本的权限边界
- `addLiquidity()` 和 `removeLiquidity()` 是 `onlyVault`
- `getPositionValue()` 是公开 `view`
- `hasPosition()` 是公开 `view`
- `collectFees()` 当前版本返回 `(0, 0)`，因为 Uniswap V2 没有独立的 fee claim 步骤，fees 已经体现在 LP position value 里

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

### 当前 V2 `params` 的语义
- `addLiquidity(amount0, amount1, params)` 和 `removeLiquidity(liquidity, params)` 都保留了 `params`
- 当前 V2 实现会把 `params` 解码为：
  - `amount0Min`
  - `amount1Min`
  - `deadline`
- 如果 `params` 为空，会使用兼容默认值：
  - `amount0Min = 0`
  - `amount1Min = 0`
  - `deadline = block.timestamp`
- 这表示：
  - manual deploy / withdraw 已经可以向 V2 adapter 传入 slippage/deadline 参数
  - redeem 已经可以通过 `withdrawalParams` 向 active V2 withdrawal 传入 slippage/deadline 参数
  - manual rebalance 已经可以通过 `withdrawalParams` 向 active V2 withdrawal 传入 slippage/deadline 参数

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

`deployToVenue(venueId, ...)` 时：
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
- `deployToVenue(venueId, ...)`：vault 的钱进对应 venue adapter，所以 vault 自己 `approve adapter`

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
  - 通过 `setVenue(...)` 注册多个 `IVenueAdapter`
  - 通过 `deployToVenue(venueId, ...)` 把 idle 资金部署到指定 venue
  - 通过 `withdrawFromVenue(venueId, liquidity, params)` 把指定 venue 的 deployed 资金撤回
  - 通过 `totalAssets()` 把 idle balances 和所有 registered venue reported amounts 一起估值
- 当前这版还没有做到：
  - 自动根据价格决定什么时候 deploy
  - 自动生成 rebalance plan
- 所以更准确地说：
  - 现在已经接通了 vault 和 adapter 的资产流主干
  - multi-venue 执行层已经接上
  - `redeem()` 已经可以按 shares 比例拆出 active venue 仓位，并支持按 venue 转发 withdrawal params
  - 但策略层还没有接上

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

## 14. V2 TWAP Oracle（当前实现）

### 这一层负责什么
- `V2TWAPOracle` 负责“价格形成”，不负责“资产执行”。
- 更准确地说：
  - adapter 负责把钱部署/撤回
  - oracle 负责给出 `price0/price1`
  - vault 负责把价格用于 `totalAssets()` 和份额相关计算

### 核心输入和输出
- 输入来自 Uniswap V2 pair：
  - `price0CumulativeLast`
  - `price1CumulativeLast`
  - `blockTimestampLast`（通过 `getReserves()` 读取）
- 输出给 vault：
  - `getPrices() -> (price0, price1)`
  - 两个价格都用 `1e18` 精度
  - 两个价格都以 oracle 配置的 `token0` 为 base
  - `price0 = 1e18`
  - `price1 = 1 个完整 token1 值多少个完整 token0`

### 核心公式
- 时间加权平均：
  - `avgX112 = (cumNow - cumLast) / timeElapsed`
- 精度转换（UQ112x112 -> 1e18）：
  - `rawPrice1e18 = avgX112 * 1e18 / 2^112`
- 最小单位比例转换为完整 token 比例：
  - `price1 = rawPrice1e18 * 10**decimals1 / 10**decimals0`

### 为什么不是直接读 reserve
- 直接读 reserve 得到的是 spot 语义，容易受短时波动影响。
- TWAP 使用 cumulative 差分/时间差，目的是用时间窗口平滑价格。

### 更新窗口约束
- `update()` 需要满足：
  - `timeElapsed > 0`
  - `timeElapsed >= minUpdateInterval`
- `minUpdateInterval` 的意义是避免更新过于频繁，导致 TWAP 退化成接近 spot。

### 初始化语义
- constructor 只做“初始快照”，不代表已经有有效 TWAP。
- 只有至少成功 `update()` 一次后，`getPrices()` 才可读。
- 在首次有效更新前，`getPrices()` 应该 revert `NotInitialized`。

### V2 原生价格与 vault 输出（最容易错）
- Uniswap V2 的原生价格是 pair-relative：
  - pair `price0` 表示 1 个 pair token0 值多少 pair token1，即 `pair token1 / pair token0`
  - pair `price1` 表示 1 个 pair token1 值多少 pair token0，即 `pair token0 / pair token1`
- 这两个原生价格的计价单位不同，不能直接作为 vault 的 `(price0, price1)` 相加估值。
- vault 输出必须统一以配置的 token0 计价，因此：
  - vault `price0` 固定为 `1e18`
  - vault `price1` 从 pair 中选择“configured token0 / configured token1”的方向
- 选择规则：
  - 若 `pair.token0 == configured token0`，使用 pair `price1AverageX112`
  - 若 `pair.token0 == configured token1`，使用 pair `price0AverageX112`
- 选出方向后还要根据 `token0Decimals/token1Decimals` 修正最小单位比例，才能得到一个完整 token1 的 token0 价格。

### UQ112x112 是什么
- `UQ112x112` 是 DeFi 常见的定点数格式（Unsigned Q-format）。
- 含义是：
  - 前 112 位表示整数部分
  - 后 112 位表示小数部分
- 真实值解释方式是：
  - `realValue = storedValue / 2^112`
- 在 Uniswap V2 里，价格比例和累计价格都围绕这个精度体系工作。
- 所以在 oracle 里必须做一次：
  - `UQ112x112 -> 1e18`
  才能和 vault 里的统一估值精度对齐。

### 为什么 UQ112x112 -> 1e18 转换要用 `mulDiv`
- 转换公式本质是：
  - `price1e18 = avgX112 * 1e18 / 2^112`
- 直接写 `avgX112 * 1e18 / 2^112` 在极端输入下有中间乘法溢出风险。
- `Math.mulDiv(a, b, d)` 的优势是：
  - 先做高精度乘除流程，避免中间乘法溢出
  - 结果语义仍然等价于 `a*b/d`
- 所以当前实现里用 `mulDiv(avgX112, 1e18, 2^112)`，更稳健。

具体为什么会有风险：
- 参与运算的三个数字量级如下：
  - `avgX112`（UQ112x112）：最大值约为 `2^224`
  - `PRECISION`（`1e18`）：约等于 `10^18`，二进制量级约为 `2^60`
  - `uint256` 容器最大容量：`2^256 - 1`
- 运算过程：
  - 当直接做 `avgX112 * 1e18` 时，中间乘积量级约为：
  - `2^224 * 2^60 = 2^284`
- 结论：
  - `2^284` 远大于 `2^256`，中间乘法会先溢出
  - 即使后面还要除以 `2^112`，也来不及，因为错误已经在乘法阶段发生
- `mulDiv` 的价值就在于避免这种“中间步骤先溢出”的问题。

### 与当前测试覆盖的对应关系
- 当前 `Oracle.t.sol` 已覆盖：
  - constructor 参数校验
  - token 集合校验
  - 初始快照正确性
  - 未初始化读价 revert
  - interval 过短/零时间 revert
  - TWAP 计算与 `1e18` 转换
  - 多窗口快照前移
  - token0 统一计价和不同 decimals 换算
  - reversed pair 下保持相同的 token0-denominated 输出

## 15. Rebalance（当前实现）

### 这一层负责什么
- `rebalance` 负责执行目标部署计划，不负责自己决定最优 venue。
- 更准确地说：
  - `deployToVenue(venueId, ...)` 负责把 idle 资金送进指定 venue adapter
  - `withdrawFromVenue(venueId, liquidity, params)` 负责把指定 venue 仓位撤回成 idle balances
  - `rebalance(targets, withdrawalParams)` 只是把“全部撤回 -> 按计划重新部署”包装成一个 owner-only 执行入口
  - `rebalanceWithStrategy(data, withdrawalParams)` 会先向已配置 strategy 要一个 plan，然后复用同一套执行逻辑

### 当前 multi-venue 模型
- 当前 vault 不再用 `IDLE / DEPLOYED_V2 / DEPLOYED_V3` 这种 enum 表示目标状态。
- 当前测试和示例里采用以下 `venueId` 约定：
  - `1`: Uniswap V2
  - `2`: Uniswap V3 0.05%
  - `3`: Uniswap V3 0.30%
  - `4`: Uniswap V3 1.00%
- 这些数字不是协议强制语义，而是 owner 在 `setVenue(...)` 里注册出来的 venue id。
- 每个 V3 fee tier 应该对应一个独立 adapter：
  - V3 0.05% -> 一个 adapter
  - V3 0.30% -> 一个 adapter
  - V3 1.00% -> 一个 adapter
- 不能把三个 V3 venue id 都指向同一个 adapter，因为当前 V3 adapter 只绑定一个 pool，并且只管理一个 active `tokenId`。
- `IDLE` 不是 venueId。当前如果要 rebalance 回 idle，传空的 `targets` 数组。
  - 如果 withdrawal 阶段需要 slippage/deadline 保护，同时传入对应的 `withdrawalParams`。

### venue registry
- 每个 venue 通过 `setVenue(venueId, adapter, label, enabled)` 注册。
- vault 里维护：
  - `venues[venueId]`
  - `venueRegistered[venueId]`
  - `venueIds`
  - `venueLiquidity[venueId]`
  - `totalLiquidity`
- `totalLiquidity` 只是 bookkeeping：
  - 它说明当前是否有 tracked liquidity
  - 但不同 venue 的 liquidity 单位不一定可比
  - 所以不能把 `totalLiquidity` 当成资产价值

### RebalanceTarget
- 当前 `rebalance` 和 strategy 返回值都使用同一个 target 类型：

```solidity
struct RebalanceTarget {
    uint256 venueId;
    uint256 amount0;
    uint256 amount1;
    bytes params;
}
```

- 含义是：
  - `venueId`：目标 venue
  - `amount0`：部署到该 venue 的 token0 原始数量
  - `amount1`：部署到该 venue 的 token1 原始数量
  - `params`：透传给 adapter 的部署参数，也就是 addLiquidity params

### VenueWithdrawalParams
- `rebalance` 和 `rebalanceWithStrategy` 都可以接收 withdrawal params：

```solidity
struct VenueWithdrawalParams {
    uint256 venueId;
    bytes params;
}
```

- 含义是：
  - `venueId`：要撤出的旧 venue
  - `params`：透传给 adapter 的 withdrawal 参数，也就是 removeLiquidity params
- 所以 rebalance 现在有两组 params：
  - `targets[i].params`：进入新 venue 时用
  - `withdrawalParams[i].params`：从旧 venue 撤出时用
- 如果某个 active venue 没有匹配的 `withdrawalParams`，vault 会向 adapter 传空 `params`。

### 当前 strategy 最小骨架
- vault 可以通过 `setStrategy(...)` 配置一个 rebalance strategy。
- strategy 只需要实现：

```solidity
function buildTargets(address vault, bytes calldata data)
    external
    view
    returns (RebalanceTypes.RebalanceTarget[] memory targets);
```

- `rebalanceWithStrategy(data, withdrawalParams)` 的流程是：
  1. 检查 strategy 是否已配置
  2. 检查 `minCooldown`，如果不为 0
  3. 检查 `maxGasPrice`，如果不为 0
  4. 检查 `minVolatilityDelta`，如果不为 0
  5. 调用 strategy 的 `buildTargets(...)`
  6. 把 strategy 返回的 targets 交给同一套 `_rebalance(...)` 执行，并把调用方传入的 withdrawal params 转发给旧 venue
  7. 成功后更新 `lastRebalance`
  8. 如果启用了 volatility guard，成功后更新 `lastRebalanceVolatilityBps`
- 这表示 strategy 只负责“生成 plan”，vault 仍然负责校验和执行。
- strategy 返回的 plan 不能绕过 vault 校验：
  - duplicate venue 会 revert
  - unset venue 会 revert
  - disabled venue 会 revert
  - 余额不足会 revert

### 当前 FixedWeightStrategy
- 当前已经有一个具体策略：[FixedWeightStrategy.sol](../contract/src/strategies/FixedWeightStrategy.sol)。
- 它的职责是：
  - 读取 vault 当前 total underlying `token0/token1` 数量
  - 按 owner 配置的固定 bps 权重拆分这些数量
  - 返回 `RebalanceTarget[]`
- 它的配置项是：

```solidity
struct TargetConfig {
    uint256 venueId;
    uint256 weightBps;
    bytes params;
}
```

- `weightBps` 使用 `10_000` 表示 100%。
- 配置规则：
  - 每个 weight 必须大于 0
  - venueId 不能重复
  - 所有 weight 加起来必须等于 `10_000`
- `buildTargets(...)` 会调用 vault 的 `getTotalUnderlying()`。
- `getTotalUnderlying()` 会把 vault idle balances 和所有 adapter-reported deployed amounts 加总。
- `buildTargets(...)` 会把整数除法产生的 rounding dust 分给最后一个 target，保证所有 target 的 `amount0/amount1` 加起来等于 vault 当前 total underlying。

当前限制：
- `FixedWeightStrategy` 使用 adapter 上报的 deployed amounts，不额外做独立市场 quote。
- 它不会计算 venue-to-venue delta。
- 它也不做 TWAP / volatility 判断。
- vault 执行时仍然会先把所有 tracked venue liquidity 撤回 idle，再按 plan 重新部署。

### 当前 VolatilityBucketStrategy
- 当前还实现了 [VolatilityBucketStrategy.sol](../contract/src/strategies/VolatilityBucketStrategy.sol)。
- 它预先保存三套权重配置：
  - `LOW`
  - `MEDIUM`
  - `HIGH`
- owner 配置两个阈值：
  - `lowVolatilityThresholdBps`
  - `highVolatilityThresholdBps`
- strategy 还会配置一个 `IVolatilityOracle`：
  - `getVolatilityBps()` 返回当前波动率，单位是 bps
- bucket 选择规则：
  - `volatilityBps <= lowThreshold`：`LOW`
  - `lowThreshold < volatilityBps <= highThreshold`：`MEDIUM`
  - `volatilityBps > highThreshold`：`HIGH`
- 当前波动率不是 strategy 自己计算的，而是从 volatility oracle 读取：

```solidity
uint256 volatilityBps = volatilityOracle.getVolatilityBps();
```

- `buildTargets(...)` 会：
  1. 从 `IVolatilityOracle` 读取 `volatilityBps`
  2. 选择对应 bucket
  3. 读取该 bucket 的 `TargetConfig[]`
  4. 调用 vault 的 `getTotalUnderlying()`
  5. 按权重拆分 vault 当前 total underlying
  6. 把 rounding dust 分给最后一个 target
  7. 如果某个 target venue 配置了 `V3TickCalculations`，则动态生成该 V3 target 的 `LiquidityParams`
- `rebalanceWithStrategy(data, withdrawalParams)` 仍然会把 `data` 透传给 strategy，但当前 `VolatilityBucketStrategy` 不使用这个参数。
- 它不再是 idle-only：
  - 会通过 `getTotalUnderlying()` 读取 idle + deployed amounts
  - 可以在 vault 已有 tracked liquidity 时生成新 plan
  - 但不计算 in-place delta，执行层仍然是先全撤再部署
- 当前它证明的是“根据外部 volatility oracle 动态选择不同权重表”。
- 当前它还可以通过 `setV3TickCalculations(venueId, calculator)` 给特定 V3 venue 配置动态 tick calculator。
- 如果 target 的 `venueId` 配了 calculator，strategy 会：
  - 调 `calculator.calculateTickRange(volatilityBps)`
  - 把返回的 `tickLower/tickUpper` 编码进 `UniswapV3Adapter.LiquidityParams`
  - 使用 `deadline = block.timestamp`
  - 如果配置了 `TwapSlippageController` 和该 venue 的 slippage params，则动态计算 `amount0Min/amount1Min`
  - 如果没有配置 slippage controller 或该 venue 的 slippage params，则保持兼容默认值 `amount0Min = 0`、`amount1Min = 0`
- 这表示 V3 动态 range 和 V3 add-liquidity 的 TWAP slippage min amount 都已经接入 strategy 层。

### 当前 TwapSlippageController
- 当前已经实现了 [TwapSlippageController.sol](../contract/src/slippage/TwapSlippageController.sol)。
- 它实现 `ISlippageController`，作用是给 strategy 生成 V3 add-liquidity 的最低可接受 token 数量。
- 它不是一个 venue adapter，不直接移动资产。
- 它的职责是：
  1. 通过 `targetVenueId` 查出该 venue 绑定的 V3 pool
  2. 确认传入 params 里的 pool 和 venue 绑定 pool 一致
  3. 用 `V3TwapLib` 读取 spot price 和 TWAP price
  4. 计算 spot-vs-TWAP deviation
  5. 如果 deviation 超过 `maxSlippageBps`，revert
  6. 如果 deviation 在允许范围内，返回：

```text
amount0Min = amount0 * (10_000 - maxSlippageBps) / 10_000
amount1Min = amount1 * (10_000 - maxSlippageBps) / 10_000
```

- `targetVenueId -> pool` 的检查是为了避免真实 fork 配置里把 V3 0.05%、0.30%、1.00% 的 pool 搞混。
- 当前 controller 保护的是 strategy 生成的 V3 add-liquidity params。
- strategy-driven withdrawal 阶段现在可以接收 owner-supplied withdrawal params；如果要让 strategy 也动态生成 remove-liquidity minimums，需要后续单独扩展。

### 当前 PriceChangeVolatilityOracle
- 当前已经实现了 [PriceChangeVolatilityOracle.sol](../contract/src/oracles/PriceChangeVolatilityOracle.sol)。
- 它实现 `IVolatilityOracle`，作用是把 `IPriceOracle` 的价格变化转换成 `volatilityBps`。
- 它从 `IPriceOracle.getPrices()` 读取：
  - `price0`
  - `price1`
- 第一次 `update()` 只初始化快照：
  - `lastPrice0`
  - `lastPrice1`
  - `lastUpdateTimestamp`
  - `volatilityBps` 仍为 `0`
- 第二次及之后的 `update()` 会计算：

```text
change0Bps = abs(price0 - lastPrice0) * 10_000 / lastPrice0
change1Bps = abs(price1 - lastPrice1) * 10_000 / lastPrice1
volatilityBps = max(change0Bps, change1Bps)
```

- 也就是说：
  - token0 变化更大，就用 token0 的变化率
  - token1 变化更大，就用 token1 的变化率
  - 一个上涨、一个下跌也不会互相抵消，因为用的是绝对变化
- 每次成功 `update()` 后都会记录 `lastUpdateTimestamp`，下一次 update 必须等待至少 `minUpdateInterval` 秒。
- 这个 interval guard 的作用是防止任何人高频调用 `update()`，把一次较大的价格变化切成很多次很小的变化，从而压低 strategy 看到的 `volatilityBps`。
- 这不是严格统计学波动率：
  - 不计算标准差
  - 不计算年化波动率
  - 不维护多周期历史窗口
- 它是当前最小实现里的 price-change proxy，用来给 `VolatilityBucketStrategy` 提供可测试的链上波动率输入。

### 当前 V3TwapVolatilityOracle
- 当前还实现了 [V3TwapVolatilityOracle.sol](../contract/src/oracles/V3TwapVolatilityOracle.sol)。
- 它也是一个 `IVolatilityOracle`，但它的 volatility 来源不是两次价格快照，而是同一个 Uniswap V3 pool 的 spot price 和 TWAP price 之间的偏离。
- 它依赖两个概念：
  - `slot0()`：读取当前 spot price，也就是“现在这一刻”的池子价格
  - `observe([twapWindow, 0])`：读取过去一段时间的 tick cumulative，用来计算 TWAP
- 它的计算心智模型是：

```text
spotPrice = 当前 pool.slot0() 对应的价格
twapPrice = 过去 twapWindow 秒的平均价格
volatilityBps = abs(spotPrice - twapPrice) * 10_000 / twapPrice
```

- 这不是严格统计学 volatility：
  - 不计算标准差
  - 不计算年化波动率
  - 不维护多周期历史收益率序列
- 它更准确地说是“spot 相对 TWAP 的偏离程度”。
- 这个信号对策略有用，因为：
  - 如果 spot 和 TWAP 很接近，说明当前价格没有明显偏离近期平均价格
  - 如果 spot 明显偏离 TWAP，说明市场可能正在快速波动，或者 spot 被短期交易影响
  - 用 TWAP 做锚点，可以降低单区块 spot manipulation 直接驱动 rebalance 的风险
- `VolatilityBucketStrategy` 不关心这个数字是怎么来的：
  - 可以来自 `MockVolatilityOracle`
  - 可以来自 `PriceChangeVolatilityOracle`
  - 也可以来自 `V3TwapVolatilityOracle`
- 它只读取统一接口：

```solidity
uint256 volatilityBps = volatilityOracle.getVolatilityBps();
```

- 当前测试已经覆盖：
  - `V3TwapVolatilityOracle` 能从 V3 mock pool 算出 TWAP price
  - spot 和 TWAP 相等时 volatility 为 `0`
  - spot 和 TWAP 不同时 volatility 大于 `0`
  - `VolatilityBucketStrategy` 能直接使用 `V3TwapVolatilityOracle` 驱动 LOW bucket target selection
  - `rebalanceWithStrategy(...)` 能执行由 `V3TwapVolatilityOracle` 驱动的 bucket plan
  - `rebalanceWithStrategy(...)` 能把 strategy 生成的 V3 target 部署进 V3 adapter
  - strategy-driven rebalance 能从 active V3 position 撤出，并把 V3 withdrawal params 转发给 adapter

### manual rebalance 和 strategy rebalance 的区别
- `rebalance(targets, withdrawalParams)`：
  - owner 手动传入 plan
  - owner 也可以为 withdrawal 阶段传入 per-venue slippage/deadline 参数
  - 如果配置了 `maxRebalanceValueLossBps`，执行结束后会检查 vault 总价值没有跌破允许下限
  - 适合测试、治理操作、emergency override
  - 不受 strategy cooldown / max gas price 限制
- `rebalanceWithStrategy(data, withdrawalParams)`：
  - owner 或配置好的 keeper 触发 strategy 生成 plan
  - withdrawal 阶段可以转发调用方传入的 per-venue params；strategy-side 自动生成 withdrawal params 仍需要后续单独设计
  - 仍然会复用同一套 rebalance value-loss guard
  - 受 `minCooldown` / `minVolatilityDelta` / `maxGasPrice` 限制
  - 成功后更新 `lastRebalance`
  - 如果启用了 volatility guard，成功后更新 `lastRebalanceVolatilityBps`

### strategy rebalance guard
- 当前 `rebalanceWithStrategy(...)` 有三类可选 guard：
  - `minCooldown`：限制两次成功 strategy rebalance 之间的最短时间
  - `maxGasPrice`：限制交易 gas price 过高时不执行
  - `minVolatilityDelta`：限制 volatility 变化太小时不执行
- 其中 `minVolatilityDelta` 的逻辑是：
  1. 从 `volatilityOracle.getVolatilityBps()` 读取当前 volatility
  2. 计算它和 `lastRebalanceVolatilityBps` 的绝对差值
  3. 如果差值小于 `minVolatilityDelta`，就 revert `VolatilityDeltaTooSmall`
- 如果 `minVolatilityDelta != 0`，必须先配置 `setVolatilityOracle(...)`。
- 这些 guard 只作用于 `rebalanceWithStrategy(...)`。
- owner 手动调用 `rebalance(targets, withdrawalParams)` 仍然是 manual override，不受这些 strategy guard 限制。

### rebalance to idle
- 如果想把所有 venue 撤回 idle：
  1. 传入空数组 `targets`
  2. 如果需要 withdrawal slippage/deadline 保护，传入对应的 `withdrawalParams`
  3. 如果 `totalLiquidity == 0`，就 `revert NoRebalanceNeeded()`
  4. vault 遍历 `venueIds`
  5. 对每个 `venueLiquidity[id] > 0` 的 venue 调 `_withdrawFromVenue(id, liquidity, params)`
  6. 检查 rebalance 前后 share supply 没有变化
  7. 如果开启了 `maxRebalanceValueLossBps`，检查 `totalAssets()` 没有低于允许下限
  8. 所有资金回到 vault idle balances

### rebalance to one or multiple venues
- 如果想部署到一个或多个 venue：
  1. 传入一个或多个 `RebalanceTarget`
  2. vault 检查是否有重复 `venueId`
  3. vault 检查非零 target 对应的 venue 是否已注册且 enabled
  4. vault 汇总本次计划需要的 `required0/required1`
  5. vault 先把所有已有 venue liquidity 撤回 idle
  6. vault 检查撤回后的 idle balances 是否足够覆盖计划
  7. vault 逐个把非零 target 部署进对应 venue
  8. 检查 rebalance 前后 share supply 没有变化
  9. 如果开启了 `maxRebalanceValueLossBps`，检查 `totalAssets()` 没有低于允许下限

### rebalance value-loss guard
- `maxRebalanceValueLossBps` 是 rebalance 的总价值下行保护。
- 默认值是 `0`，表示关闭检查。
- 非零时，rebalance 会在执行前记录：
  - `totalSupply()`
  - `totalAssets()`
- 执行完成后检查：

```text
totalSupplyAfter == totalSupplyBefore
totalAssetsAfter >= totalAssetsBefore * (10_000 - maxRebalanceValueLossBps) / 10_000
```

- 这个 guard 只限制 downside，不限制 upside。
- 如果 rebalance 后 `totalAssets()` 变大，合约不会 revert，因为 fees、donation、价格变化都可能让用户受益。
- 但如果在测试环境里没有 fees、donation 或价格变化，`totalAssets()` 明显变大，应该优先排查估值或会计问题，比如 reserves 没同步、token 顺序映射错误、V3 principal 计算不一致。

### strategy 如何处理“venue 里已经有仓位”
- 当前 strategy 不是只看 idle balance。
- `FixedWeightStrategy` 和 `VolatilityBucketStrategy` 都会读取：

```solidity
(uint256 total0, uint256 total1) = vault.getTotalUnderlying();
```

- 这里的 `total0/total1` 包括：
  - vault 直接持有的 idle token
  - 所有 registered adapter 通过 `getPositionValue()` 上报的 deployed token amounts
- 所以如果资金已经在 V2 里，strategy 仍然可以生成“全部去另一个 venue”的 plan。
- 但这个 plan 只是目标状态，不是精细 delta。
- 真正执行时，vault 仍然会：
  1. 先把所有 tracked venue liquidity 撤回 idle
  2. 检查 idle balances 是否够覆盖 strategy plan
  3. 再按 strategy plan 部署到目标 venues
- 这就是现在的“total-underlying strategy + withdraw-all-then-redeploy executor”模型。

### 为什么当前实现是“先全撤，再部署”
- 这是最小实现的刻意选择：
  - accounting 简单
  - 测试简单
  - 不需要先做 venue-to-venue delta 计算
  - 不需要处理某个 venue 增仓、另一个 venue 减仓的复杂路径
- 代价是：
  - gas 更高
  - 对真实 AMM 来说可能多一次退出和进入
- 后续如果做策略层，可以再优化成 delta rebalance。

### 权限和边界
- `rebalance()` 是 owner-only 策略入口
- `rebalanceWithStrategy()` 可以由 owner 或 configured keeper 调用
- keeper 是 execution-only，不能修改 strategy、oracle、venue，也不能执行 emergency 管理操作
- `setVenue()` 在目标 venue 仍有 tracked liquidity 或 adapter-reported position 时会 revert
- `rebalance()` 会拒绝 duplicate venue target
- `rebalance()` 会拒绝 unset 或 disabled venue
- `rebalance()` 会拒绝超过可用余额的 target plan
- 这样可以避免：
  - adapter 切换后，vault 里的部署会计和真实仓位脱节
  - rebalance 读到的状态和实际资产流不一致

### 当前 oracle / strategy 的职责边界
- `V2TWAPOracle`：
  - 是 `IPriceOracle`
  - 给 vault 的 `totalAssets()`、deposit/share 计算提供 token 价格
  - 返回的是 `(price0, price1)`
- `PriceChangeVolatilityOracle`：
  - 是 `IVolatilityOracle`
  - 读取 `IPriceOracle` 的价格快照变化
  - 输出 `volatilityBps`
- `V3TWAPOracle`：
  - 是 V3 TWAP reader 基类
  - 从 V3 pool 的 `observe(...)` 计算 TWAP price
  - 不直接做 bucket selection
- `V3TwapVolatilityOracle`：
  - 是 `IVolatilityOracle`
  - 使用 V3 pool 的 `slot0()` 和 `observe(...)`
  - 输出 spot-vs-TWAP deviation 的 `volatilityBps`
- `VolatilityBucketStrategy`：
  - 不直接读 AMM pool
  - 不自己计算 TWAP
  - 只消费 `IVolatilityOracle.getVolatilityBps()`
  - 根据 LOW / MEDIUM / HIGH bucket 生成 rebalance targets
- vault：
  - 不负责决定 volatility 怎么算
  - 不负责决定 bucket 怎么选
  - 只负责验证和执行 strategy 生成的 rebalance plan

### 当前测试覆盖的对应关系
- 当前 rebalance 相关测试覆盖：
  - rebalance 只能由 owner 调用
  - idle 余额可以部署到 V2
  - idle 余额可以部署到 V3
  - idle 余额可以按 plan 拆到多个 venue
  - 多个 venue 可以一起撤回 idle
  - 重复 venue target 会 revert
  - unset / disabled venue 会 revert
  - target plan 超过可用余额会 revert
  - 没有可移动资金时会 revert `NoRebalanceNeeded`
  - active venue 存在时禁止更新对应 venue adapter
  - strategy 未配置时会 revert
  - configured keeper 可以执行 `rebalanceWithStrategy`
  - 非 owner 且非 keeper 的地址调用 `rebalanceWithStrategy` 会 revert
  - strategy-driven rebalance 会更新 `lastRebalance`
  - cooldown / max gas price guard 会限制 strategy-driven rebalance
  - volatility oracle 未配置时启用 volatility guard 会 revert
  - volatility delta 太小时 strategy-driven rebalance 会 revert
  - 成功的 strategy-driven rebalance 会更新 `lastRebalanceVolatilityBps`
  - strategy 返回 unset venue 时仍然会走 vault 原有校验并 revert
  - FixedWeightStrategy 会按固定 bps 生成 targets
  - FixedWeightStrategy 会把 rounding dust 分给最后一个 target
  - vault 可以执行 FixedWeightStrategy 生成的最小 V2 plan
  - FixedWeightStrategy 可以把已部署 venue 的资金迁移到新的 venue allocation
  - VolatilityBucketStrategy 会按 LOW / MEDIUM / HIGH 选择不同权重配置
  - VolatilityBucketStrategy 会把 rounding dust 分给最后一个 target
  - vault 可以执行 VolatilityBucketStrategy 生成的最小 V2 plan
  - VolatilityBucketStrategy 可以把已部署 venue 的资金迁移到新的 venue allocation
  - PriceChangeVolatilityOracle 会初始化价格快照
  - PriceChangeVolatilityOracle 会处理上涨、下跌、一个涨一个跌的价格变化
  - PriceChangeVolatilityOracle 会取 token0/token1 中更大的价格变化作为 `volatilityBps`
  - vault 可以执行由 PriceChangeVolatilityOracle 驱动的 VolatilityBucketStrategy plan

## 16. Uniswap V3 Adapter

### 相关概念

#### Tick
- `tick` 是 Uniswap V3 用来表示价格位置的离散编号。
- 可以粗略理解成：连续价格曲线被切成很多很细的格子，每个格子编号就是一个 tick。
- tick 越大，表示 token1 相对 token0 的价格越高；tick 越小，表示价格越低。
- V3 pool 的 `slot0()` 会返回当前 active tick，也就是当前价格所在的 tick。

#### Tick Range
- V3 LP position 不是像 V2 那样覆盖所有价格。
- 一个 V3 position 只在 `[tickLower, tickUpper]` 这个价格区间内提供流动性。
- 如果当前 tick 在这个区间内，position 同时持有两种 token，并参与做市。
- 如果当前 tick 跑到区间外，position 会变成几乎单边资产，并停止在当前价格附近赚取交易费。

#### tickLower / tickUpper
- `tickLower` 是 position 的下边界。
- `tickUpper` 是 position 的上边界。
- 必须满足：
  - `tickLower < tickUpper`
  - 两个 tick 都必须对齐 pool 的 `tickSpacing()`
- V3 position NFT 创建后，这个 range 本身不能通过 `increaseLiquidity()` 改变。
- 如果策略想换成新的 range，应该撤掉旧 position，再 mint 新 position。

#### tickSpacing
- `tickSpacing` 是某个 V3 pool 允许使用的 tick 间距。
- 不是所有整数 tick 都能作为 position 边界。
- 例如 `tickSpacing = 60` 时，合法边界只能是：
  - `... -120, -60, 0, 60, 120 ...`
- 常见 fee tier 和 spacing 的关系是：
  - `0.05% fee`，fee tier 参数是 `500`，对应 `tickSpacing = 10`
  - `0.30% fee`，fee tier 参数是 `3000`，对应 `tickSpacing = 60`
  - `1.00% fee`，fee tier 参数是 `10000`，对应 `tickSpacing = 200`
- 所以计算出来的 raw tick range 必须 round 到合法 spacing 后才能传给 V3 position manager。

#### tickRange
- 在 `V3TickCalculations` 里，`tickRange` 表示围绕当前 tick 左右展开的 raw 宽度。
- 当前实现把 volatility 映射成三个宽度：
  - 低波动：`200`
  - 中波动：`500`
  - 高波动：`1500`
- 直觉是：
  - 波动越低，可以使用更窄、更集中的 range
  - 波动越高，需要更宽的 range，降低价格很快跑出区间的概率
- 注意这里的 `tickRange` 不是最终合法边界，只是计算 raw lower/upper 的中间值。

### 当前阶段的目标
- 当前 V3 adapter 的目标不是一次性实现多 fee tier 策略。
- 当前最小目标是：
  - 一个 adapter 只绑定一个 V3 pool
  - 一个 pool 自然对应一个 fee tier
  - 一个 adapter 只管理一个 V3 position NFT
  - 先跑通 `deploy / withdraw / collectFees / totalAssets` 这条链路

更准确地说：
- 现在先验证 vault 的 `IVenueAdapter` 抽象能不能无痛替换成 V3 venue。
- 不要先把 adapter 做成多 position / 多 fee tier manager。
- 多 fee tier 更像后续 strategy manager 或 venue manager 的职责。

### 当前 `IVenueAdapter`
- 当前 `IVenueAdapter` 已经有：
  - `addLiquidity(amount0, amount1, params)`
  - `removeLiquidity(liquidity, params)`
  - `collectFees()`
  - `getPositionValue()`
  - `hasPosition()`
- 对最小 V3 adapter 来说，这组接口暂时够用，并且 remove 侧 `params` 已经为后续 slippage-protected withdrawal 预留。
- 关键原因是：
  - V3 的 `tokenId` 可以由 adapter 内部保存
  - vault 不需要知道具体 NFT 编号
  - `params` 可以承载 V3 特有的 `amountMin/deadline`
  - `liquidity` 可以表示当前 V3 position 的 liquidity 数量
  - `getPositionValue()` 返回的是 vault 语义的 token0/token1 估值，而不是 pool 语义

什么时候才需要改接口：
- 如果一个 adapter 要同时管理多个 V3 NFT position
- 如果 vault 或策略层需要显式指定撤哪一个 `tokenId`
- 如果一个 adapter 要同时管理 `0.05% / 0.30% / 1.00%` 多个 fee tier
- 这时才应该把 position identity 暴露到接口层，或者新增更高层的 strategy manager。

### V3 里的 position 是什么
- `positionManager` 不是 position 本身。
- `positionManager` 是管理 V3 position NFT 的合约。
- `tokenId` 是某一个 V3 position NFT 的编号。
- `position` 是通过：
  - `positionManager.positions(tokenId)`
  查出来的那条仓位记录。

可以这样记：
- `positionManager` = 仓位登记处和操作入口
- `tokenId` = 仓位 NFT 编号
- `position` = `positions(tokenId)` 返回的仓位数据

所以 adapter 的生命周期是：
1. constructor 阶段没有 `tokenId`
2. 第一次 `addLiquidity()` 调 `mint(...)`
3. `mint(...)` 返回 `tokenId`
4. adapter 保存这个 `tokenId`
5. 之后 `increaseLiquidity / decreaseLiquidity / collect / burn` 都围绕这个 `tokenId` 操作

### constructor 应该做什么
- constructor 只负责静态配置校验，不负责创建仓位。
- 它应该检查：
  - `vault/token0/token1/positionManager/pool` 都不是零地址
  - `tickLower < tickUpper`
  - `pool.token0/token1` 与 vault 配置的 `token0/token1` 是同一组 token
- 它应该保存：
  - `vault`
  - `token0`
  - `token1`
  - `positionManager`
  - `pool`
  - `defaultTickLower`
  - `defaultTickUpper`

为什么 constructor 不校验 `tokenId`：
- `tokenId` 是第一次 `mint()` 之后才产生的运行时状态。
- constructor 运行时还没有 V3 position NFT。
- 所以 `tokenId == 0` 应该表示“当前还没有 position”。

### addLiquidity 的 params 语义
- 当前 V3 版本的 `params` 放执行参数和 mint range：
  - `amount0Min`
  - `amount1Min`
  - `deadline`
- `tickLower`
- `tickUpper`
- `amount0/amount1` 本身已经由函数参数传入：
  - `addLiquidity(amount0, amount1, params)`
- 所以不要再在 `params` 里重复放 `amount0Desired/amount1Desired`。

当前 adapter 内部定义：
- `LiquidityParams { amount0Min, amount1Min, deadline, tickLower, tickUpper }`

空 `params` 会使用：
- `amount0Min = 0`
- `amount1Min = 0`
- `deadline = block.timestamp`
- constructor 里的默认 `defaultTickLower/defaultTickUpper`

非空 `params` 可以覆盖 mint 新 position 时的 tick range。
如果已有 position，`params` 里的 tick range 必须和当前 NFT position 里存的 tick range 一致，否则 adapter 会 revert `TickRangeMismatch`。

tick range 有两个基本约束：
- `tickLower < tickUpper`
- `tickLower/tickUpper` 必须对齐 pool 的 `tickSpacing()`

这一步让 adapter 具备“执行动态 range”的能力。adapter 仍然只负责执行和校验，不负责根据市场状态做策略判断。
根据 volatility/current tick 自动计算 range 的逻辑放在独立的 `V3TickCalculations` 里；后续 strategy/rebalance 层可以调用它生成传给 adapter 的 `LiquidityParams.tickLower/tickUpper`。

### V3TickCalculations
`V3TickCalculations` 是 V3 tick range 的独立计算模块。

算法逻辑是：
1. 从 `v3Pool.slot0()` 读取当前 active tick，作为本次 range 的中心参考点。
2. 根据 `volatilityBps` 映射到 raw tick width：
   - `< 50 bps`: `200`
   - `< 150 bps`: `500`
   - `>= 150 bps`: `1500`
3. 先计算未对齐的原始区间：
   - `rawLower = currentTick - tickRange`
   - `rawUpper = currentTick + tickRange`
4. 从 `v3Pool.tickSpacing()` 读取当前池子的合法 tick 间距。
5. 将 `rawLower` 向下 round 到合法 spacing，得到 `tickLower`。
6. 将 `rawUpper` 向上 round 到合法 spacing，得到 `tickUpper`。

这里的 rounding 原则是“向外扩”，不是“向内收”。
也就是说，最终合法区间必须完整覆盖原始 raw range：
- lower 只能往更小的 tick 方向调整
- upper 只能往更大的 tick 方向调整

不能把 lower 往上收，也不能把 upper 往下收；否则最终 position range 会比策略想要的 raw range 更窄，可能更容易掉出区间。

这里也不能简单依赖 Solidity 整数除法截断，因为 Solidity 对负数除法会向 0 截断。
例如 spacing 为 `60` 时，raw lower `-1` 应该变成 `-60`，raw upper `1` 应该变成 `60`。
这样最终 range 才能完整覆盖 raw target range。

当前 `VolatilityBucketStrategy` 可以按 `venueId` 配置 `V3TickCalculations`。
当 strategy 生成 rebalance target 时，如果某个 V3 venue 配置了 calculator，它会自动调用 `calculateTickRange(volatilityBps)`，再把结果编码进 `UniswapV3Adapter.LiquidityParams.tickLower/tickUpper`。

这一步已经把“动态 tick range 计算”从独立模块接到了 strategy 层。
当前 strategy 还可以接入 `TwapSlippageController`，在生成 V3 add-liquidity params 时同时填入 TWAP 校验后的 `amount0Min/amount1Min`。

### addLiquidity 最小流程
- `addLiquidity()` 负责把 vault 的 idle token 部署进 V3 position。
- 它不负责选 fee tier，不负责策略判断。
- 它可以执行 params 传入的 tick range，但不负责根据市场状态计算这个 range。

流程是：
1. 如果 `amount0 == 0 && amount1 == 0`，revert
2. 解码 `params`
3. 调 `_addLiquidity(amount0, amount1, params)`
4. `_addLiquidity()` 拉币、建上下文、授权、执行、退 dust、清授权
5. emit `LiquidityAdded`

关键规则：
- 函数入参 `amount0/amount1` 是 vault 语义。
- `MintParams.amount0Desired/amount1Desired` 是 pool 语义。
- position manager 的授权也必须按 pool 语义的 token 地址和数量来设置。
- `mint/increaseLiquidity` 返回的 used amounts 也是 pool 语义。
- 退 dust 时必须映射回 vault 语义。
- V3 NFT 的 tick range 创建后不能通过 `increaseLiquidity()` 改变；如果目标 range 改了，应该先撤旧仓位再 mint 新仓位，而不是对旧 NFT 直接 increase。

### removeLiquidity 最小流程
- `removeLiquidity(liquidity, params)` 负责从当前 V3 position 里撤出指定 liquidity。
- 当前 V3 remove 会把 `params` 解码成 `amount0Min/amount1Min/deadline`。
- 这些 minimum amounts 以 vault token 顺序传入，adapter 会映射成 pool token 顺序后再传给 `decreaseLiquidity`。
- 如果 `params` 为空，会使用兼容默认值：`amount0Min = 0`、`amount1Min = 0`、`deadline = block.timestamp`。

流程是：
1. 如果 `liquidity == 0`，revert
2. 如果 `tokenId == 0`，revert
3. 读取 `positions(tokenId)` 的当前 liquidity
4. 如果请求撤出的 liquidity 超过当前 liquidity，revert
5. 调用 `decreaseLiquidity(...)`
6. 调用 `collect(...)` 把撤仓本金和任何可领取 token 收到 adapter
7. 把 collected amounts 从 pool 语义映射回 vault 语义
8. 转回 vault
9. 再读一次 position 状态
10. 如果 liquidity 和 owed tokens 都为 0，调用 `burn(tokenId)`
11. 清空 adapter 里的 `tokenId`
12. emit `LiquidityRemoved`

为什么 `decreaseLiquidity()` 后还要 `collect()`：
- V3 的 `decreaseLiquidity()` 只是减少 position 的 liquidity。
- 真正把 token 拿出来，需要再调用 `collect()`。

### collectFees 最小流程
- V3 和 V2 不同，V3 有显式 fee collection。
- 所以 `collectFees()` 在 V3 adapter 里应该真实执行；V2 adapter 则返回 `(0, 0)` 作为 no-op。

流程是：
1. 如果没有 active position，revert
2. 调用 `positionManager.collect(...)`
3. `amount0Max/amount1Max` 使用 `type(uint128).max`
4. 把 collected amounts 从 pool 顺序映射回 vault 顺序
5. 转回 vault
6. 如果 position 已经完全空了，burn NFT 并清空 `tokenId`
7. emit `FeesCollected`

注意：
- V3 的 `collect()` 可能收回 position manager 当前记录的所有可领取 token。
- 它不一定只代表狭义的 swap fee。
- 如果刚刚执行过 `decreaseLiquidity()`，`collect()` 也可能收回撤仓产生的 principal。

### getPositionValue 最小语义
- `getPositionValue()` 应该返回当前 V3 position 对应的底层 token 数量。
- 返回顺序必须是 vault 的 `token0/token1` 顺序。

当前实现的最小口径是：
- active liquidity 对应的 principal
- `tokensOwed0/tokensOwed1`

流程是：
1. 如果 `tokenId == 0`，返回 `(0, 0)`
2. 读取 `positions(tokenId)`
3. 先把 `tokensOwed0/tokensOwed1` 作为 owed component
4. 如果 liquidity 非零：
   - 读取 `pool.slot0()` 的 `sqrtPriceX96`
   - 用 position NFT 里存储的 `tickLower/tickUpper` 调 `TickMath.getSqrtRatioAtTick(...)` 得到区间边界
   - 用 `LiquidityAmounts.getAmountsForLiquidity(...)` 算 principal
5. principal + owed 得到 pool 语义 amount
6. 映射回 vault 语义

补充说明：
- 如果 position 只有 owed、没有 liquidity，`getPositionValue()` 仍应返回非零值。

重要限制：
- 这版估值是“position-manager-tracked 值 + 当前本金”，能覆盖已记账的 owed amounts。
- 它不会重建尚未写入 `tokensOwed0/1` 的最新 fee growth，所以不是完整会计意义上的精确净值。
- 如果后面要做份额定价或审计级估值，需要再补 V3 fee growth accounting。

### hasPosition 最小语义
- `hasPosition()` 不只是判断 `tokenId != 0`。
- 更稳的语义是：
  - `tokenId == 0` -> false
  - 否则读取 `positions(tokenId)`
  - 如果 `liquidity > 0` 或 `tokensOwed0 > 0` 或 `tokensOwed1 > 0` -> true
  - 否则 false

为什么不能只看 `tokenId != 0`：
- 如果 position 已经全撤、fees 也收完，但没有清理 `tokenId`，就会出现 stale tokenId。
- 所以 `removeLiquidity()` 和 `collectFees()` 在完全空仓后应该：
  - `burn(tokenId)`
  - `tokenId = 0`

### 当前的 helper 拆分
当前实现已经把职责拆清楚了：

- `_mapVaultToPool(...)`
  - 把 vault 语义的 token / amount / min 映射到 pool 语义
- `_mapTokenAmounts(...)`
  - 通用的 token 顺序金额映射 helper
- `_getPositionMetadata(...)`
  - 仅读取 `positions(tokenId)` 中需要的字段
- `_hasActivePosition(...)`
  - 判断 position 是否还“活着”
- `_collectAndTransfer(...)`
  - `collect()` 到 adapter，再转给 vault
- `_cleanupEmptyPosition()`
  - 位置彻底空了就 burn + 清 `tokenId`
- `_buildAddLiquidityContext(...)`
  - 构造 add-liquidity 执行上下文
- `_executeAddLiquidity(...)`
  - 分派 mint / increase 并返回 used amounts
- `_mintPosition(...)`
  - 真正调用 `positionManager.mint(...)`
- `_validateCurrentPositionTicks(...)`
  - 已有 position 时，检查本次 params 里的 tick range 是否和当前 NFT position 的 tick range 一致
- `_increasePosition(...)`
  - 真正调用 `positionManager.increaseLiquidity(...)`
- `_refundDust(...)`
  - 把没用完的 vault token 退回 vault

### V3 测试需要哪些 mock
- 第一批测试不建议直接接真实 Uniswap V3。
- 先用 mock 验证 adapter 自己的资金流、权限、token 顺序映射和 tokenId 生命周期。

最少需要：
- `MockERC20`
- `MockUniswapV3Pool`
- `MockNonfungiblePositionManager`

`MockUniswapV3Pool` 最少需要：
- `token0()`
- `token1()`
- `fee()`
- `slot0()`
- 测试辅助函数：
  - `setSlot0FromTick(...)`
  - `setSlot0(...)`

`MockNonfungiblePositionManager` 最少需要：
- `mint(...)`
- `increaseLiquidity(...)`
- `decreaseLiquidity(...)`
- `collect(...)`
- `positions(tokenId)`
- `burn(tokenId)`
- 测试辅助函数：
  - `setNextMintResult(...)`
  - `setNextIncreaseResult(...)`
  - `setNextDecreaseResult(...)`
  - `setTokensOwed(...)`

第一版不一定需要单独 mock ERC721：
- 因为当前重点是 adapter 的资金流和 position state
- 不需要先完整复刻 V3 NFT 行为

第一版也不一定需要 mock vault：
- adapter 只检查 `msg.sender == vault`
- 测试里可以用 `vm.prank(vault)` 模拟 vault 调用

### V3 测试优先级
- constructor 保存配置
- constructor 拒绝零地址
- constructor 拒绝非法 tick
- constructor 拒绝 token 集合不匹配的 pool
- `hasPosition()` 在没有 tokenId 时返回 false
- `addLiquidity()` 在零金额时 revert
- `addLiquidity()` 首次 mint 后保存 `tokenId`
- `addLiquidity()` 有已有 position 时走 `increaseLiquidity`
- `addLiquidity()` 有已有 position 且 params 传入不同 tick range 时 revert
- `addLiquidity()` 能退回 dust
- `removeLiquidity()` 能撤出 token 并转回 vault
- `removeLiquidity()` 在完全空仓后清掉 `tokenId`
- `collectFees()` 能把 collected token 转回 vault
- `getPositionValue()` 返回 zeroes without a position
- `getPositionValue()` 包含 principal 和 position-manager-tracked owed tokens
- `getPositionValue()` 使用 position NFT 自己存的 tick range，而不是 adapter 的默认 tick range
- `getPositionValue()` 在只有 owed、没有 liquidity 时仍应返回非零值
- 非 vault 调用状态变更函数会 revert

`getPositionValue()` 的完整数学测试可以放在第二批：
- 需要先引入或本地化 `TickMath`
- 需要先引入或本地化 `LiquidityAmounts`
- 再测价格在区间内、区间左侧、区间右侧三种情况

### V3 集成测试
- 在 adapter 单测稳定后，再新增一组 vault 级集成测试，例如 `VaultV3Integration.t.sol`
- 这组测试的目标不是重复 adapter 的内部细节，而是验证 vault 到 V3 的完整闭环
- 最小闭环建议覆盖：
  - `setVenue()` 正确接入 V3 adapter
  - `deposit -> deployToVenue(venueId, ...) -> redeem` 可以通过 redeem 自动按比例撤出 active V3 仓位
  - full redeem 会清理整个 active V3 position
  - partial redeem 会保留原 `tokenId`，只减少 position liquidity
  - `totalAssets()` 会把 `adapter.getPositionValue()` 算进去
  - 当 `adapter.hasPosition()` 为 true 时，redeem 会撤出对应比例 liquidity 并清理 fully redeemed position
  - strategy-driven rebalance 可以把 idle 资金部署进 V3，并验证 dynamic tick / slippage params 被传到 V3 mint
  - strategy-driven rebalance 可以从 V3 撤出，并验证 withdrawal params 被传到 V3 decrease liquidity
- `harvestVenueFees(venueId)` 允许 owner 或 keeper 在不撤仓的情况下，把 venue 可收取的 token 收回 vault idle；该操作在 paused 状态仍可执行，因为它只回收资产，不重新承担 AMM 风险。
- `redeem(...)` 会在读取 idle balance 前，对所有 venue 执行 collect。这样历史 V3 fees 先进入 idle，再按 `shares / totalSharesBefore` 分配给赎回者；随后按比例撤出的 liquidity 不会再次收取整个 position 的历史 fees。
- 因此 partial redeem 的 V3 fees 已按 shares 精确分配：赎回者得到自己的比例，剩余部分留在 vault，属于剩余 shares。
- `compoundVenueFees(venueId, params)` 会在同一笔交易中 collect 后重新部署到相同 venue。对于已有且 tick range 匹配的 V3 NFT，adapter 会调用 `increaseLiquidity`，不需要全撤、burn NFT 或重新 mint。
- harvest 和 compound 都需要 owner 或 keeper 主动发交易；合约没有内置定时器。keeper 应在链下结合 gas 成本、slippage params 和执行频率决定何时调用。
- `collectFees()` 是 adapter 的通用接口名；对 V3 而言它收取的是 position manager 当前记录的 owed tokens，其中可能同时包含 swap fees 和此前 `decreaseLiquidity` 产生的 owed tokens。

### V3 集成测试边界
- 当前 mock 版本里，token 余额最终会落在 `MockNonfungiblePositionManager`，这是简化实现，不是链上真实 V3 的最终托管位置
- 如果后面要做真实 V3 对照，再补 fork test 或更贴近真实池子资金流的 mock
