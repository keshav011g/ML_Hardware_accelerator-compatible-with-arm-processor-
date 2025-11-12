# ML_Hardware_accelerator-compatible-with-arm-processor-
This a hardware implementation of custom Digital IC, the standard architecture for a powerful hardware accelerator that commonly connects to an ARM processor (or similar RISC based processors) on a larger SoC.
### Understanding DMA-Enabled ML Accelerator

This an advanced and highly effective architecture for an ML accelerator, commonly found in high-performance computing and embedded AI systems. This design leverages **DMA (Direct Memory Access)** to avoid the CPU bottleneck, allowing this custom chip to operate at maximum efficiency.

#### The Big Picture: CPU + Accelerator + RAM
![This is the alt text for my image](/images/ml_accelerator_schematic.jpg)
Imagine your entire system as three main components:

1.  **CPU (Central Processing Unit):**
    * **Role:** It runs the high-level software (your application), manages the operating system, and sends commands to the accelerator.
    * **Interaction:** Communicates with your accelerator's **control registers** via a low-bandwidth **AXI-Lite bus**.(maybe a memory mapped register interface)

2.  **External RAM (DDR/SRAM):**
    * **Role:** The "Storage" for all large data: your ML model weights, the input images/text, and the final results.
    * **Interaction:** Both the CPU and your accelerator can access this, but the accelerator does so directly via a high-bandwidth **AXI-Master bus** using DMA.

3.  **Your Verilog Accelerator IC:**
    * **Role:** It performs the heavy mathematical calculations of ML inference in parallel, at high speed.
    * **Interaction:**
        * **Receives commands** from the CPU (via AXI-Lite).
        * **Directly reads/writes large data** from/to external RAM (via AXI-Master DMA).
        * **Processes data** internally using its specialized `ml_processing_unit`.
        * **Notifies the CPU** when it's done (via an interrupt or status register).

#### How It Works: The Workflow

This is the exact sequence of events for performing an ML inference:

1.  **CPU Sets Up RAM (Software):**
    * Your CPU (running C++ code) first loads the ML model's **weights** from its own storage (e.g., flash memory, SSD) into a specific region of the **external RAM**. It knows the *start address* and *size* of these weights.
    * Similarly, it loads the **input data** (image pixels, text embeddings) into another specific region of the **external RAM**. It notes its *start address* and *size*.
    * It designates a third region in external RAM for the **output results**.

2.  **CPU Configures Accelerator (AXI-Lite Writes):**
    * The CPU writes to your accelerator's **control registers** (defined in `ml_accelerator_top.v`):
        * `ADDR_WGT_BASE_ADDR`: Where the weights begin in RAM.
        * `ADDR_WGT_SIZE`: How many bytes of weights.
        * `ADDR_INPUT_BASE_ADDR`: Where the input begins in RAM.
        * `ADDR_INPUT_SIZE`: How many bytes of input.
        * `ADDR_OUTPUT_BASE_ADDR`: Where the results should be written in RAM.
        * `ADDR_OP_CODE_REG`: This is crucial! It tells the accelerator *what kind of ML operation* to perform (e.g., a Convolutional Layer, a Fully Connected Layer, a ReLU activation, etc.).
        * `ADDR_OP_PARAMS_REG_0`, `ADDR_OP_PARAMS_REG_1`: Parameters for that operation (e.g., filter size, stride, number of channels, input tensor dimensions).

3.  **CPU Initiates Accelerator (AXI-Lite Write):**
    * The CPU writes a `1` to `ADDR_CONTROL_REG` (specifically, setting the `cpu_start_accel` bit). This is the "Go!" command.
    * The CPU is now **free** to do other tasks! It doesn't need to babysit the data transfer.

4.  **Accelerator Takes Over (DMA & Internal Computation):**
    * Your accelerator's main **FSM** (`current_state` in `ml_accelerator_top.v`) starts its sequence:
        * **`FSM_DMA_READ_WEIGHTS`:** It activates the internal `dma_controller.v`. The DMA controller independently reads the weights from the `ADDR_WGT_BASE_ADDR` in external RAM and streams them directly into the `ml_processing_unit.v`.
        * **`FSM_DMA_READ_INPUT`:** Once weights are transferred, the DMA controller reads the input data from `ADDR_INPUT_BASE_ADDR` in external RAM and streams it into the `ml_processing_unit.v`.
        * **`FSM_COMPUTE`:** The `ml_processing_unit.v` takes the streamed data and, using the `op_code` and `op_params`, performs the specified ML operation (e.g., a massive matrix multiplication for a convolutional layer). This happens at your IC's maximum clock speed and parallelism ("minimum clock cycle").
        * **`FSM_DMA_WRITE_OUTPUT`:** The `ml_processing_unit.v` streams its results to the DMA controller, which then writes them back to the `ADDR_OUTPUT_BASE_ADDR` in external RAM.

5.  **Accelerator Signals Completion (Interrupt / Status Register):**
    * Once the DMA write is complete, the FSM transitions to `FSM_DONE`.
    * It sets the "Done" bit in `ADDR_STATUS_REG` and sends an **interrupt** signal to the CPU.

6.  **CPU Retrieves Results:**
    * The CPU receives the interrupt (or periodically polls `ADDR_STATUS_REG`).
    * It then directly reads the results from the `ADDR_OUTPUT_BASE_ADDR` in external RAM, knowing that the accelerator has placed them there.

#### Why This Is Fast and Flexible

* **DMA for Speed:** The CPU is never involved in moving large blocks of data. The DMA controller does it directly and very efficiently. This is critical for high-bandwidth applications like image processing.
* **Programmable Accelerator:** By writing `op_code` and `op_params` to registers, your single `ml_processing_unit.v` can perform *different types of ML operations*. This means it's not hardwired for just one model. You can chain together multiple operations (e.g., CONV -> RELU -> POOL -> FC) by sending a sequence of commands to the accelerator.
* **Minimum Clock Cycle Core:** The `ml_processing_unit.v` itself contains the highly parallel, pipelined hardware (like systolic arrays) that performs the actual mathematical operations in the fastest possible way.

* **Hardware Instructions:** A set of **primitive operations** that your hardware can perform.
    * **Common ML Primitives:**
        * Matrix Multiplication (Multiply-Accumulate, MAC) - for Convolutional and Fully Connected layers
        * Element-wise Addition/Subtraction/Multiplication
        * Activation Functions (ReLU, Sigmoid, Tanh) - usually implemented as lookup tables or simple comparators.
        * Pooling (Max Pool, Average Pool)
        * Normalization (Batch Norm)
    * Your `ml_processing_unit.v` would have dedicated, optimized hardware blocks for each of these primitives.

* **Software Layer:(after we are done with the verilog implementation)** We would then write a software library (e.g., a C++ library on the CPU) that breaks down a full ML model (like a TensorFlow Lite model) into a sequence of these primitive operations. The CPU then sends these operations, one by one, to your accelerator.

        accelerator.wait_for_interrupt();
        // ... and so on for each layer of the model
        ```

This modular approach allows you to implement various ML models by simply changing the sequence of primitive operations and their parameters that the CPU sends to your versatile hardware accelerator.
