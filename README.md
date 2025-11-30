# 🚀 High-Performance ML Hardware Accelerator (ARM Compatible)

> **A dedicated hardware IP core designed to offload heavy Matrix-Multiply-Accumulate (MAC) operations from ARM processors for efficient Edge AI inference.**

## 📖 Overview

This repository contains the complete **Register Transfer Level (RTL)** implementation of a custom Digital AI Accelerator. It is architected to bridge the gap between low-power embedded CPUs (like the ARM Cortex-M series) and the high compute demands of modern Deep Learning models.

By offloading the computationally expensive matrix math to this dedicated hardware, systems can achieve **100x-1000x efficiency gains** compared to software-based execution.

## ✨ Key Features

* **16x16 Systolic Array Core:** Massively parallel execution engine capable of performing **256 MAC operations per clock cycle**.
* **Weight-Stationary Dataflow:** Optimized architecture that minimizes energy-expensive memory accesses by reusing weights within the Processing Elements (PEs).
* **Hardware Tiling Engine:** Automatically breaks down large matrices (e.g., 100x100) to fit onto the 16x16 physical core without software intervention.
* **Automatic Zero Padding:** Hardware logic handles "ragged edges" (matrix sizes not divisible by 16) transparently.
* **DMA-Enabled:** Integrated Direct Memory Access (DMA) controller to fetch weights and inputs autonomously, preventing CPU starvation.
* **ARM-Ready Interface:** Standard AXI-Lite register map for seamless integration with AMBA-based SoCs.

## 🏗️ System Architecture

The system is designed as a modular co-processor.

### 1. The Host Ecosystem
* **CPU (ARM Cortex):** Acts as the orchestrator. It parses the neural network layers, sets up the memory pointers, and issues the "Start" command.
* **External RAM (DDR):** Holds the heavy model weights and input buffers (images/audio).

### 2. The Accelerator IP
* **Control Unit (AXI-Lite):** A memory-mapped slave interface. The CPU communicates with the chip by writing to specific memory addresses (e.g., `0x4000_0000`).
* **DMA Controller (AXI-Master):** A bus master that bursts large blocks of data from external RAM into the chip's internal SRAM buffers.
* **Internal SRAM Buffers:**
  * **Weight Buffer (32KB):** Caches model parameters.
  * **Input Buffer (16KB):** Caches incoming feature maps.
  * **Accumulator Buffer (16KB):** Stores partial sums before final write-back.
* **Systolic Core:** The 16x16 grid of Processing Elements that performs the actual INT8 math.

## ⚙️ Technical Specifications

| Feature | Specification |
| :--- | :--- |
| **Precision** | INT8 (8-bit Integer) Inputs / INT24 Accumulation |
| **Core Size** | 16x16 Grid (256 Processing Elements) |
| **Throughput** | 256 Operations / Cycle |
| **Memory Interface** | AXI4-Master (128-bit Data Width) |
| **Control Interface** | AXI4-Lite (32-bit Data Width) |
| **On-Chip Memory** | ~64 KB (Configurable SRAM Macros) |
| **Target Frequency** | 200 MHz+ (on 28nm ASIC) / 100 MHz (on Artix-7 FPGA) |

## 🛠️ Hardware Integration (Register Map)

To control the accelerator from C/C++ code, use the following register offsets from the base address:

| Offset | Register Name | Access | Description |
| :--- | :--- | :--- | :--- |
| `0x00` | **REG_CONTROL** | Write | Write `0x1` to START the engine. |
| `0x04` | **REG_STATUS** | Read | `Bit 0`: Busy, `Bit 1`: Done. |
| `0x08` | **REG_M_SIZE** | R/W | Number of rows in the Input Matrix. |
| `0x0C` | **REG_K_SIZE** | R/W | Shared dimension (Input Cols / Weight Rows). |
| `0x10` | **REG_N_SIZE** | R/W | Number of columns in the Weight Matrix. |

**Example Driver Code:**
```c
void run_inference(int rows, int cols, int depth) {
    *REG_M_SIZE = rows;
    *REG_N_SIZE = cols;
    *REG_K_SIZE = depth;
    *REG_CONTROL = 1; // Start
    while(!(*REG_STATUS & 0x02)); // Wait for Done
}
