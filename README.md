# Cognichip-Hackathon-by-Train-Neo-Bit
EcoTraining: An Energy-Efficient Hardware Design for Gradient Compression in LLM Training

# Energy-Efficient-Hardware-Design-in-LLM-Training

Improving Energy Efficiency in AI Accelerators via Intelligent Gradient Compression

In the era of large-scale AI models, the "Memory Wall" has emerged as a critical bottleneck, where the energy and latency costs of moving data between compute units and off-chip memory (DRAM/HBM) far exceed those of the computation itself. This is particularly evident in distributed training, where constant gradient updates create massive write traffic. We propose a Hardware-based Gradient Compressor that acts as an intelligent shim layer. By leveraging an on-chip SRAM-based accumulation buffer, the module filters out insignificant gradient updates and only performs high-energy DRAM writes for substantial weight changes. This architectural optimization significantly reduces memory bandwidth pressure and overall power consumption, maintaining high throughput for next-generation AI workloads.

It includes our three design by Congnichip Platform. The main design is included in the "Final Design/cognichip" folder. Please feel free to check each design and run the testbench.

Team Members: 

[Feiyu Jia, 2001, fj2182@nyu.edu, Assistant Director]

[Heng Pu, 1999, hp2723@nyu.edu, Assistant Director]

[Lixuan Xu, 2003, lx2349@nyu.edu, Assistant Director]

[Yuhan Jiang, 2003, yj3494@nyu.edu, Assistant Director]


Video files:
https://drive.google.com/drive/folders/1FBsTOAM3yhlfgYb_FIVgTlXZeEpj_-cW?usp=sharing
