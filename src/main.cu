#include <iostream>
#include <string>
#include <curand_kernel.h>

#include "camera.cuh"
#include "entitylist.cuh"
#include "float.h"
#include "sphere.cuh"
#include "lambertian.cuh"
#include "metal.cuh"
#include "transparent.cuh"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#define checkCudaErrors(val) check_cuda( (val), #val, __FILE__, __LINE__ )
void check_cuda(cudaError_t result, char const *const func, const char *const file, int const line) {
    if (result) {
        std::cerr << "CUDA error = " << static_cast<unsigned int>(result) << " at " <<
        file << ":" << line << " '" << func << "' \n";
        // Make sure we call CUDA Device Reset before exiting
        cudaDeviceReset();
        exit(99);
    }
}

__device__ Vec3 color(const Ray& r, Entity **world, curandState *local_rand_state) {
    Ray cur_ray = r;
    Vec3 cur_attenuation = Vec3(1.0,1.0,1.0);
    for(int i = 0; i < 50; i++) {
        HitRecord rec;
        if ((*world)->hit(cur_ray, 0.001f, FLT_MAX, rec)) {
            Ray scattered;
            Vec3 attenuation;
            if(rec.mat_ptr->scatter(cur_ray, rec, attenuation, scattered, local_rand_state)) {
                cur_attenuation *= attenuation;
                cur_ray = scattered;
            }
            else {
                return Vec3(0.0,0.0,0.0);
            }
        }
        else {
            Vec3 unit_direction = unitv(cur_ray.direction());
            float t = 0.5f*(unit_direction.y() + 1.0f);
            Vec3 c = (1.0f-t)*Vec3(1.0, 1.0, 1.0) + t*Vec3(0.5, 0.7, 1.0);
            return cur_attenuation * c;
        }
    }
    return Vec3(0.0,0.0,0.0); // exceeded recursion
}

#define RND (curand_uniform(&local_rand_state))

__global__ void create_world(Entity **elist, Entity **eworld, Camera **camera, int nx, int ny, curandState *rand_state) {
    if (threadIdx.x == 0 && blockIdx.x == 0) {
        curandState local_rand_state = *rand_state;
        elist[0] = new Sphere(Vec3(0,-1000.0,-1), 1000,
                               new Lambertian(Vec3(0.5, 0.5, 0.5)));
        int i = 1;
        for(int a = -11; a < 11; a++) {
            for(int b = -11; b < 11; b++) {
                float choose_mat = RND;
                Vec3 center(a+RND,0.2,b+RND);
                if(choose_mat < 0.8f) {
                    elist[i++] = new Sphere(center, 0.2,
                                             new Lambertian(Vec3(RND*RND, RND*RND, RND*RND)));
                }
                else if(choose_mat < 0.95f) {
                    elist[i++] = new Sphere(center, 0.2,
                                             new Metal(Vec3(0.5f*(1.0f+RND), 0.5f*(1.0f+RND), 0.5f*(1.0f+RND)), 0.5f*RND));
                }
                else {
                    elist[i++] = new Sphere(center, 0.2, new Transparent(1.5));
                }
            }
        }
        elist[i++] = new Sphere(Vec3(0, 1,0),  1.0, new Transparent(1.5));
        elist[i++] = new Sphere(Vec3(-4, 1, 0), 1.0, new Lambertian(Vec3(0.4, 0.2, 0.1)));
        elist[i++] = new Sphere(Vec3(4, 1, 0),  1.0, new Metal(Vec3(0.7, 0.6, 0.5), 0.0));
        *rand_state = local_rand_state;
        *eworld = new EntityList(elist, 22*22+1+3);

        Vec3 lookfrom(13,2,3);
        Vec3 lookat(0,0,0);
        float dist_to_focus = 10.0; (lookfrom-lookat).l2();
        float aperture = 0.1;
        *camera = new Camera(lookfrom, lookat, Vec3(0,1,0), 30.0, float(nx) / float(ny), aperture, dist_to_focus);
    }
}

__global__ void free_world(Entity **elist, Entity **eworld, Camera **camera) {
    for(int i = 0; i < 22 * 22 + 1 + 3; i++) {
        delete ((Sphere*)elist[i])->mat_ptr;
        delete elist[i];
    }
    delete *eworld;
    delete *camera;
}

__global__ void rand_init(curandState *rand_state) {
    if (threadIdx.x == 0 && blockIdx.x == 0) {
        curand_init(1984, 0, 0, rand_state);
    }
}

__global__ void render_init(int maxx, int maxy, curandState *rand_state) {
    int i = threadIdx.x + blockIdx.x * blockDim.x;
    int j = threadIdx.y + blockIdx.y * blockDim.y;
    if((i >= maxx) || (j >= maxy)) return;
    int pixel_index = j*maxx + i;
    curand_init(1984, pixel_index, 0, &rand_state[pixel_index]);
}

__global__ void render(Vec3* fb, int max_x, int max_y, int ns, Camera **cam, Entity **world, curandState *randState) {
    int i = threadIdx.x + blockIdx.x * blockDim.x;
    int j = threadIdx.y + blockIdx.y * blockDim.y;
    if((i >= max_x) || (j >= max_y)) return;
    int pixel_index = j*max_x + i;
    curandState local_rand_state = randState[pixel_index];
    Vec3 col(0,0,0);
    for(int s=0; s < ns; s++) {
        float u = float(i + curand_uniform(&local_rand_state)) / float(max_x);
        float v = float(j + curand_uniform(&local_rand_state)) / float(max_y);
        Ray r = (*cam)->get_ray(u, v, &local_rand_state);
        col += color(r, world, &local_rand_state);
    }
    randState[pixel_index] = local_rand_state;
    col /= float(ns);
    col[0] = sqrt(col[0]);
    col[1] = sqrt(col[1]);
    col[2] = sqrt(col[2]);
    fb[pixel_index] = col;
}

int main(int argc, char* argv[]) {
    if (argc < 5) {
        std::cerr << "Usage: " << argv[0] << " [WIDTH] [HEIGHT] [BOUNCES] [OUTPUT FILENAME]" << std::endl;
    }
    int nx = std::stoi(std::string(argv[1]));
    int ny = std::stoi(std::string(argv[2]));
    int ns = std::stoi(std::string(argv[3]));
    int tx = 16;
    int ty = 16;
    
    // Values
    int num_pixels = nx * ny;

    // Allocating CUDA memory
    Vec3* image;
    checkCudaErrors(cudaMallocManaged((void**)&image, nx * ny * sizeof(Vec3)));

    // Allocate random state
    curandState *d_rand_state;
    checkCudaErrors(cudaMalloc((void **)&d_rand_state, num_pixels * sizeof(curandState)));
    curandState *d_rand_state2;
    checkCudaErrors(cudaMalloc((void **)&d_rand_state2, 1 * sizeof(curandState)));

    // Allocate 2nd random state to be initialized for the world creation
    rand_init<<<1,1>>>(d_rand_state2);
    checkCudaErrors(cudaGetLastError());
    checkCudaErrors(cudaDeviceSynchronize());

    // Building the world
    Entity **elist;
    int num_entity = 22*22+1+3;
    checkCudaErrors(cudaMalloc((void **)&elist, num_entity * sizeof(Entity*)));
    Entity **eworld;
    checkCudaErrors(cudaMalloc((void **)&eworld, sizeof(Entity*)));
    Camera **camera;
    checkCudaErrors(cudaMalloc((void **)&camera, sizeof(Camera*)));
    create_world<<<1, 1>>>(elist, eworld, camera, nx, ny, d_rand_state2);
    checkCudaErrors(cudaGetLastError());
    checkCudaErrors(cudaDeviceSynchronize());

    dim3 blocks(nx/tx+1,ny/ty+1);
    dim3 threads(tx,ty);
    render_init<<<blocks, threads>>>(nx, ny, d_rand_state);
    checkCudaErrors(cudaGetLastError());
    checkCudaErrors(cudaDeviceSynchronize());
    render<<<blocks, threads>>>(image, nx, ny,  ns, camera, eworld, d_rand_state);
    checkCudaErrors(cudaGetLastError());
    checkCudaErrors(cudaDeviceSynchronize());
    
    uint8_t* imageHost = new uint8_t[nx * ny * 3 * sizeof(uint8_t)];
    for (int j = ny - 1; j >= 0; j--) {
        for (int i = 0; i < nx; i++) {
            size_t pixel_index = j * nx + i;
            imageHost[(ny - j - 1) * nx * 3 + i * 3] = 255.99 * image[pixel_index].r();
            imageHost[(ny - j - 1) * nx * 3 + i * 3 + 1] = 255.99 * image[pixel_index].g();
            imageHost[(ny - j - 1) * nx * 3 + i * 3 + 2] = 255.99 * image[pixel_index].b();
        }
    }
    stbi_write_png(argv[4], nx, ny, 3, imageHost, nx * 3);

    // Clean up
    checkCudaErrors(cudaDeviceSynchronize());
    free_world<<<1,1>>>(elist, eworld, camera);
    checkCudaErrors(cudaGetLastError());
    checkCudaErrors(cudaFree(camera));
    checkCudaErrors(cudaFree(eworld));
    checkCudaErrors(cudaFree(elist));
    checkCudaErrors(cudaFree(d_rand_state));
    checkCudaErrors(cudaFree(image));
}