# Orbital Hook: 3-Asset Concentrated Liquidity on Uniswap V4

**Orbital** is a novel Automated Market Maker (AMM) design implemented as a Uniswap V4 Hook. It brings the efficiency of concentrated liquidity to pools with three or more stablecoins.

## 🚀 What We Built

We built a **Uniswap V4 Hook** that manages a custom liquidity curve for 3 assets (USDC, USDT, DAI). Unlike standard Uniswap V3/V4 pools which are pairwise (2 assets), Orbital allows for multi-asset swaps within a single pool structure by managing the accounting and math externally in the hook.

Read more about Orbital from the official paradigm blog post: [Orbital](https://www.paradigm.xyz/2025/06/orbital)

### Key Features:

- **3-Asset Pool**: Supports swapping between USDC, USDT, and DAI in a single pool.
- **Concentrated Liquidity**: Uses a spherical cap geometry ("Orbits") to concentrate liquidity around the $1.00 peg.
- **Custom Accounting**: Bypasses the standard PoolManager liquidity system to implement custom 3-asset reserves and pricing logic.

## 💡 How It Works (Simple Terms)

Imagine a standard liquidity pool as a balance scale with two buckets. If you add to one, the other goes up. This works great for 2 tokens.

**Orbital** changes the geometry. Instead of a line or a curve on a 2D plane, imagine a **sphere** in 3D space.

- The "perfect price" (1:1:1) is the center of the sphere.
- Liquidity is provided in "orbits" around this center.
- When you swap, you move along the surface of this sphere.

This allows us to have a single pool where you can swap USDC -> DAI, DAI -> USDT, or USDT -> USDC, all using the same shared liquidity, which is much more efficient than having three separate pools (USDC/DAI, DAI/USDT, USDT/USDC).

<details>
<summary><strong>📐 Detailed Math Logic (Click to Expand)</strong></summary>

### The Orbital Invariant

The core invariant for the Orbital curve is based on the equation of a sphere (or hypersphere for n > 3).

For 3 assets with reserves $x, y, z$, and a large radius parameter $R$:

$$ (R - x)^2 + (R - y)^2 + (R - z)^2 = L^2 $$

Where:

- $R$ is a large constant (the "Radius" of the universe).
- $x, y, z$ are the normalized balances of the tokens in the pool.
- $L$ is the current "distance" from the origin (related to the total liquidity).

### Swap Math

When a user swaps $\Delta x$ (input) for $\Delta y$ (output):

1. **Calculate New X**: $x_{new} = x + \Delta x$
2. **Calculate New Y Term**:
   We solve for the new $y$ that keeps $L^2$ constant.
   $$ (R - x*{new})^2 + (R - y*{new})^2 + (R - z)^2 = L^2 $$
   $$ (R - y*{new})^2 = L^2 - (R - x*{new})^2 - (R - z)^2 $$
3. **Solve for Output**:
   $$ y*{new} = R - \sqrt{(R - y*{new})^2} $$
   $$ \Delta y = y - y\_{new} $$

This formula ensures that the "distance" $L$ remains constant during a swap, similar to how $x \cdot y = k$ keeps the product constant in Uniswap V2.

</details>

## 🛠️ How to Run Locally

You can simulate the Orbital Hook logic locally using Foundry. We have set up a script that forks Ethereum Mainnet to use real USDC, USDT, and DAI tokens.

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed.

### Steps

1. **Clone the repo**

   ```bash
   git clone <repo-url>
   ```

2. **Run the Interaction Script**
   This script deploys the hook to a local fork, adds liquidity, and performs a swap, logging all the balance changes to the console.

   ```bash
   forge script script/OrbitalInteraction.s.sol \
     --fork-url https://eth-mainnet.g.alchemy.com/v2/YOUR_ALCHEMY_KEY \
     -vvvv
   ```

   _(Replace `YOUR_ALCHEMY_KEY` with a valid Mainnet RPC URL)_

3. **What to Expect**
   You will see logs showing:
   - The deployment of the OrbitalHook.
   - "Adding Liquidity": Balances of the user decreasing and the Hook increasing.
   - "L_SQUARED updated": The invariant being calculated.
   - "Swapping": The user sending USDC and receiving USDT based on the Orbital curve math.

## NOTES

- The current implementation is a prototype for demonstration purposes. It may not be optimized for gas efficiency or security for production use.
- The current implementation assumes the fees to be 0.1% which is hardcoded in the swap logic, and causing the major deviation from the ideal invariant curve.

## Future Work

- **Gas Optimization**: Refine the hook logic to minimize gas costs.
- **Pool Tick Management**: Implement tick management for better liquidity concentration even in orbital harnessing the actual benefits of Orbital.

## 📜 License

MIT
