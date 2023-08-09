# "3D Gaussian Splatting for Real-Time Radiance Field Rendering" Reproduction in C++ and CUDA
This repository contains a reproduction of the Gaussian-Splatting software, originally developed by Inria and the Max Planck Institut for Informatik (MPII). The reproduction is written in C++ and CUDA.

I embarked on this project to deepen my understanding of the groundbreaking paper on 3D Gaussian splatting, by reimplementing everything from scratch.

## About this Project
This project is a derivative of the original Gaussian-Splatting software and is governed by the Gaussian-Splatting License, which can be found in the LICENSE file in this repository. The original software was developed by Inria and MPII.

Please be advised that the software in this repository cannot be used for commercial purposes without explicit consent from the original licensors, Inria and MPII.

## Current Measurments as of 2023-08-09 
NVIDIA GeForce RTX 4090

    tandt/truck:
        ~122 seconds for 7000 iterations (original PyTorch implementation)
        ~120 seconds for 7000 iterations (my initial implementation)

While completely unoptimized, the gains in performance, though modest, are noteworthy.

=> Next Goal: Achieve 60 seconds for 7000 iterations in my implementation
## libtorch
Initially, I utilized libtorch to simplify the development process. Once the implementation is stable with libtorch, I will begin replacing torch elements with my custom CUDA implementation.

To download the libtorch library (cuda version), use the following command:
```bash
wget https://download.pytorch.org/libtorch/test/cu118/libtorch-cxx11-abi-shared-with-deps-latest.zip  
```
Then, extract the downloaded zip file with:

```bash
unzip libtorch-cxx11-abi-shared-with-deps-latest.zip -d external/
rm libtorch-cxx11-abi-shared-with-deps-latest.zip
```
This will create a folder named `libtorch` in the `external` directory of your project.

## TODO (in no particular order, reminders for myself)
- [x] Camera stuff is weird. Needs rework.
- [x] The gaussian initialization is not correct. Differs from original implementation.
- [ ] Need to think about the cameras. Separating camera and camera_info seems useless.
- [x] The ply after x iterations cannot be saved. Need to implement this.
- [ ] Proper logging. (Lets see, low prio)
- [ ] Proper config file or cmd line config.
- [x] Need to implement the rendering part. First sketch is there.
- [x] Remove bugs. Important! Seems to train properly.
- [x] Initially implement full 1:1 capable version minus some extra stuff.

## MISC
Here is random collection of things that have to be described in README later on
- Needed for simple-knn: 
```bash sudo apt-get install python3-dev ```
- Patch pybind in libtorch on Linux; nvcc encounters issues with a template definition. 
- For glm in diff-gaussian-rasterization, run: ```bash git submodule update --init --recursive ```

## Citation and References
If you utilize this software or present results obtained using it, please reference the original work:

Kerbl, Bernhard; Kopanas, Georgios; Leimkühler, Thomas; Drettakis, George (2023). [3D Gaussian Splatting for Real-Time Radiance Field Rendering](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/). ACM Transactions on Graphics, 42(4).

This will ensure the original authors receive the recognition they deserve.

## License

This project is licensed under the Gaussian-Splatting License - see the [LICENSE](LICENSE) file for details.

Follow me on Twitter if you want to know about the current development: https://twitter.com/janusch_patas