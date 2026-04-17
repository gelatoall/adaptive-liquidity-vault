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
- 在 idle vault 里，它由以下几部分计算得到：
  - vault 当前持有的 token0 数量
  - vault 当前持有的 token1 数量
  - 当前价格

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

### 重要细节
- `deposit` 必须使用转账前的 `totalAssets`。
- 否则用户自己的存款会先被算进 vault，总价值分母会出错。

### Redeem
- `redeem` 的流程是：
  - `shares -> ownership ratio -> amount0Out/amount1Out`
- `redeem` 会按 shares 占比返还底层 token。

### Redeem 的输出公式
- `amount0Out = vaultBalance0 * shares / totalSupplyBefore`
- `amount1Out = vaultBalance1 * shares / totalSupplyBefore`

### 重要细节
- `redeem` 必须使用 burn 前的 `totalSupply`。

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
- 更准确地说，`token0.balanceOf(address(vault))` 更像是 vault 当前的 `totalAmount0`。
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
- `vault.totalAssets()` 只有在特殊情况下才会和 `totalSupply()` 数值相等
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

## 9. 我已经发现的常见错误

- 混淆 `amount`、`assets` 和 `shares`
- 混淆 `totalSupply()` 和 `totalAssets()`
- 在 `redeem` 检查里错误地用 `totalSupply` 代替 `balanceOf(msg.sender)`
- burn 了底层资产数量，而不是 burn shares
- 用 price 单位去期待 token 输出数量

## 10. Uniswap V2 基础概念

### Pair
- `pair` 是池子本体合约。
- 它持有 `token0` 和 `token1` 的储备。
- 它也是 LP token 的发行者。
- 在 V2 里，真正装着资产、维护池子状态的是 `pair`，不是 `router`。
- 因为 `pair` 会 mint LP token，所以它本身也带有 ERC20 风格的能力，例如：
  - `balanceOf(address)`
  - `totalSupply()`
- 但在当前项目里，更适合把它理解成：
  - 一个池子合约
  - 同时也暴露出 LP token 相关函数

### Router
- `router` 是操作入口。
- 它帮助用户或 adapter 添加和移除流动性。
- `router` 不是池子本体，也不是最终持有储备的地方。
- 对 adapter 来说，`router` 主要解决的是“怎么执行 add/remove liquidity”。

### Reserve
- `reserve0` 和 `reserve1` 表示 `pair` 当前记录的两种 token 储备量。
- 可以先把它理解成：池子当前装着多少 `token0` 和多少 `token1`。
- 在 adapter 里，`reserve` 最重要的用途是把 LP 份额换算成底层 token 数量。

### LP Token
- LP token 是对 `pair` 的份额凭证。
- 持有多少 LP token，就代表拥有这条池子的相应比例。
- 例如，如果 adapter 持有总 LP 供应量的 10%，那么它就拥有池子储备的 10%。

### V2 Position Value
- 在当前项目里，`getPositionValue()` 这个名字虽然叫 value，但当前返回的是底层 `amount0` 和 `amount1`。
- 它不是价格换算后的标准化资产价值。
- 在职责上：
  - adapter 负责返回底层 token 数量
  - vault 再负责结合价格把它们并入 `totalAssets()`

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
- 在 Solidity 里把命名返回值又声明成了局部变量

## 11. ERC20、IERC20、SafeERC20 的区别

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

## 12. 我当前的心智模型

- `amount` = token 数量
- `assets` = 标准化后的统一价值
- `shares` = vault 所有权份额

- `deposit` = token 进来，shares 出去
- `redeem` = shares 进来，token 出去

- `totalAssets` = vault 当前总价值
- `totalSupply` = vault 当前总 shares

- `totalAssets` 和 `totalSupply` 在初始化阶段可能数值相等
- 但它们语义始终不同：一个表示总价值，一个表示总份额
