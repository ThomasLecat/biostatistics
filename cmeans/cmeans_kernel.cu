#include <stdio.h>
#include <stdlib.h>
#include <cutil.h>
#include <cmeans.h>
#include <cmeanscu.h>
#include <float.h>

/* 
 * Raises a float to a integer power using a loop and multiplication
 * Much faster than the generic pow(float,float) from math.h
 */
__device__ float ipow(float val, int power) {
    float tmp = val;
    for(int i=0; i < power-1; i++) {
        tmp *= val;
    }
    return tmp;
}

__device__ float parallelSum(float* data, const unsigned int ndata) {
  const unsigned int tid = threadIdx.x;
  float t;

  __syncthreads();

  // Butterfly sum.  ndata MUST be a power of 2.
  for(unsigned int bit = ndata >> 1; bit > 0; bit >>= 1) {
    t = data[tid] + data[tid^bit];  __syncthreads();
    data[tid] = t;                  __syncthreads();
  }
  return data[tid];
}

/*
 * Computes centers with a MxD grid
 */
__global__ void UpdateClusterCentersGPU(const float* oldClusters, const float* events, float* newClusters, float* memberships) {

	float membershipValue;//, denominator;

    int d = blockIdx.y;
    int event_matrix_offset = NUM_EVENTS*d;
    int membership_matrix_offset = NUM_EVENTS*blockIdx.x;

	__shared__ float numerators[NUM_THREADS_UPDATE];

    // Sum of the memberships computed by each thread
    // The sum of all of these denominators together is effectively the size of the cluster
	__shared__ float denominators[NUM_THREADS_UPDATE];
		
    int tid = threadIdx.x;

    // initialize numerators and denominators to 0
    denominators[tid] = 0;
    numerators[tid] = 0;

    __syncthreads();


    // Compute new membership value for each event
    // Add its contribution to the numerator and denominator for that thread
    for(int j = tid; j < NUM_EVENTS; j+=NUM_THREADS_UPDATE){
        membershipValue = memberships[membership_matrix_offset + j];
        numerators[tid] += events[event_matrix_offset + j]*membershipValue;
        denominators[tid] += membershipValue;
    } 

    __syncthreads();

    if(tid == 0){
        // Sum up the numerator/denominator, one for this block
        for(int j = 1; j < NUM_THREADS_UPDATE; j++){
            numerators[0] += numerators[j];
        }  
        for(int j = 1; j < NUM_THREADS_UPDATE; j++){
            denominators[0] += denominators[j];
        }
        // Set the new center for this block	
        newClusters[blockIdx.x*NUM_DIMENSIONS + d] = numerators[0]/denominators[0];
    }
}

/* 
 * Computes numerators of the centers with a M/B x D grid, where B is the number of clusters per block
 * 
 * This should be more efficient because it only acceses event data M/B times, rather than M times
 * Shared memory limits B to 15, but 4 seems to be ideal for performance (still has good 50+% occupacy)
 */
__global__ void UpdateClusterCentersGPU2(const float* oldClusters, const float* events, float* newClusters, float* memberships) {
	float membershipValue;
    float eventValue;

    // Compute cluster range for this block
    int c_start = blockIdx.x*NUM_CLUSTERS_PER_BLOCK;
    int num_c = NUM_CLUSTERS_PER_BLOCK;
    
    // Handle boundary condition
    if(blockIdx.x == gridDim.x-1 && NUM_CLUSTERS % NUM_CLUSTERS_PER_BLOCK) {
        num_c = NUM_CLUSTERS % NUM_CLUSTERS_PER_BLOCK;
    }
    
    // Dimension index
    int d = blockIdx.y;
    int event_matrix_offset = NUM_EVENTS*d;

	__shared__ float numerators[NUM_THREADS_UPDATE*NUM_CLUSTERS_PER_BLOCK];
		
    int tid = threadIdx.x;
    
    // initialize numerators and denominators to 0
    for(int c = 0; c < num_c; c++) {    
        numerators[c*NUM_THREADS_UPDATE+tid] = 0;
    }
       
    // Compute new membership value for each event
    // Add its contribution to the numerator and denominator for that thread
    for(int j = tid; j < NUM_EVENTS; j+=NUM_THREADS_UPDATE){
        eventValue = events[event_matrix_offset + j];
        for(int c = 0; c < num_c; c++) {    
            membershipValue = memberships[(c+c_start)*NUM_EVENTS + j];
            numerators[c*NUM_THREADS_UPDATE+tid] += eventValue*membershipValue;
        }
    } 

    __syncthreads();

    for(int c = 0; c < num_c; c++) {   
        numerators[c*NUM_THREADS_UPDATE+tid] = parallelSum(&numerators[NUM_THREADS_UPDATE*c],NUM_THREADS_UPDATE);
    }
 
    __syncthreads();

    if(tid == 0){
        for(int c = 0; c < num_c; c++) {   
            // Set the new center for this block	
            newClusters[(c+c_start)*NUM_DIMENSIONS + d] = numerators[c*NUM_THREADS_UPDATE];
        }
    }

}

__global__ void ComputeDistanceMatrix(const float* clusters, const float* events, float* matrix) {
    // copy the relavant center for this block into shared memory	
    __shared__ float center[NUM_DIMENSIONS];
    for(int j = threadIdx.x; j < NUM_DIMENSIONS; j+=NUM_THREADS_DISTANCE){
        center[j] = clusters[blockIdx.y*NUM_DIMENSIONS+j];
    }

    __syncthreads();

    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if(i < NUM_EVENTS) {
        matrix[blockIdx.y*NUM_EVENTS+i] = CalculateDistanceGPU(center,events,blockIdx.y,i);
    }
}

__global__ void ComputeDistanceMatrixNoShared(float* clusters, const float* events, float* matrix) {
    
    float* center = &clusters[blockIdx.y*NUM_DIMENSIONS];

    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if(i < NUM_EVENTS) {
        matrix[blockIdx.y*NUM_EVENTS+i] = CalculateDistanceGPU(center,events,blockIdx.y,i);
    }
}

__global__ void ComputeMembershipMatrix(float* distances, float* memberships) {
    float membershipValue;

    int i = blockIdx.x * blockDim.x + threadIdx.x;
    // For each event
    if(i < NUM_EVENTS) {
        membershipValue = MembershipValueGPU(blockIdx.y, i, distances);
        #if FUZZINESS_SQUARE 
            // This is much faster than the pow function
            membershipValue = membershipValue*membershipValue;
        #else
            membershipValue = __powf(membershipValue,FUZZINESS)+1e-30;
        #endif
        memberships[blockIdx.y*NUM_EVENTS+i] = membershipValue;
    }
}

__global__ void ComputeMembershipMatrixLinear(float* distances) {
    float membershipValue;
    float denom = 0.0f;
    float dist;

    int i = blockIdx.x * blockDim.x + threadIdx.x;
    // For each event
    if(i < NUM_EVENTS) {
        for(int c=0; c < NUM_CLUSTERS; c++) {
            dist = distances[c*NUM_EVENTS+i];
            #if FUZZINESS_SQUARE 
                dist = dist*dist;
            #else
                dist = __powf(dist,2.0f/(FUZZINESS-1.0f))+1e-30;
            #endif
            denom += 1.0f / dist;
        }
        
        for(int c=0; c < NUM_CLUSTERS; c++) {
            // not enough shared memory to store an array of distances
            // for each thread, so just recompute them like above
            dist = distances[c*NUM_EVENTS+i];
            #if FUZZINESS_SQUARE 
                dist = dist*dist;
                membershipValue = 1.0f/(dist*denom); // u
                membershipValue *= membershipValue; // u^p, p=2
            #else
                dist = __powf(dist,2.0f/(FUZZINESS-1.0f))+1e-30;
                membershipValue = 1.0f/(dist*denom); // u
                membershipValue = __powf(membershipValue,FUZZINESS); // u^p
            #endif
            distances[c*NUM_EVENTS+i] = membershipValue;
        } 
    }
}

__global__ void ComputeNormalizedMembershipMatrix(float* distances, float* memberships) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if(i < NUM_EVENTS) {
        memberships[blockIdx.y*NUM_EVENTS+i] = MembershipValueGPU(blockIdx.y, i, distances);
    }
}

__global__ void ComputeNormalizedMembershipMatrixLinear(float* distances) {
    float membershipValue;
    float denom = 0.0f;
    float dist;

    int i = blockIdx.x * blockDim.x + threadIdx.x;
    // For each event
    if(i < NUM_EVENTS) {
        for(int c=0; c < NUM_CLUSTERS; c++) {
            dist = distances[c*NUM_EVENTS+i];
            #if FUZZINESS_SQUARE 
                dist = dist*dist;
            #else
                dist = __powf(dist,2.0f/(FUZZINESS-1.0f))+1e-30;
            #endif
            denom += 1.0f / dist;
        }
        
        for(int c=0; c < NUM_CLUSTERS; c++) {
            // not enough shared memory to store an array of distances
            // for each thread, so just recompute them like above
            dist = distances[c*NUM_EVENTS+i];
            #if FUZZINESS_SQUARE 
                dist = dist*dist;
                membershipValue = 1.0f/(dist*denom); // u
            #else
                dist = __powf(dist,2.0f/(FUZZINESS-1.0f))+1e-30; 
                membershipValue = 1.0f/(dist*denom); // u
            #endif
            distances[c*NUM_EVENTS+i] = membershipValue;
        } 
    }
}

__device__ float MembershipValueGPU(int clusterIndex, int eventIndex, const float* distanceMatrix){
	float myClustDist = 0.0f;
    // Compute the distance from this event to the given cluster
    myClustDist = distanceMatrix[clusterIndex*NUM_EVENTS+eventIndex];
	
	float sum = 0.0f;
	float otherClustDist;
	for(int j = 0; j< NUM_CLUSTERS; j++){
        otherClustDist = distanceMatrix[j*NUM_EVENTS+eventIndex];

        #if FUZZINESS_SQUARE 
            sum += (myClustDist/otherClustDist)*(myClustDist/otherClustDist);
        #else
    		sum += __powf((myClustDist/otherClustDist),(2.0f/(FUZZINESS-1.0f)));
        #endif
        //sum += ipow(myClustDist/otherClustDist,2/(FUZZINESS-1));
	}
	return 1.0f/sum;
}


__global__ void ComputeClusterSizes(float* memberships, float* sizes) {
    __shared__ float partial_sums[512];

    partial_sums[threadIdx.x] = 0.0f;
    for(int i=threadIdx.x; i < NUM_EVENTS; i += 512) {
        partial_sums[threadIdx.x] += memberships[blockIdx.x*NUM_EVENTS+i];
    }

    __syncthreads();

    float sum = parallelSum(partial_sums,512);

    __syncthreads();

    if(threadIdx.x) {
        sizes[blockIdx.x] = sum;
    }
    
}
__device__ float MembershipValueDist(int clusterIndex, int eventIndex, float distance, float* distanceMatrix){
	float sum =0.0f;
	float otherClustDist;
	for(int j = 0; j< NUM_CLUSTERS; j++){
        otherClustDist = distanceMatrix[j*NUM_EVENTS+eventIndex];
        #if FUZZINESS_SQUARE 
            sum += (distance/otherClustDist)*(distance/otherClustDist);
        #else
            sum += __powf((distance/otherClustDist),(2.0f/(FUZZINESS-1.0f)));
        #endif
		//sum += ipow((distance/otherClustDist),2/(FUZZINESS-1));
	}
	return 1.0f/sum;
}

__device__ float CalculateDistanceGPU(const float* center, const float* events, int clusterIndex, int eventIndex){

	float sum = 0;
	float tmp;
    #if DISTANCE_MEASURE == 0 // Euclidean
        #pragma unroll 1 // Prevent compiler from unrolling this loop, eats up too many registers
        for(int i = 0; i < NUM_DIMENSIONS; i++){
            tmp = events[i*NUM_EVENTS+eventIndex] - center[i];
            //tmp = events[eventIndex*NUM_DIMENSIONS + i] - clusters[clusterIndex*NUM_DIMENSIONS + i];
            sum += tmp*tmp;
        }
        //sum = sqrt(sum);
        sum = sqrt(sum+1e-30);
    #endif
    #if DISTANCE_MEASURE == 1 // Absolute value
        #pragma unroll 1 // Prevent compiler from unrolling this loop, eats up too many registers
        for(int i = 0; i < NUM_DIMENSIONS; i++){
            tmp = events[i*NUM_EVENTS+eventIndex] - center[i];
            //tmp = events[eventIndex*NUM_DIMENSIONS + i] - clusters[clusterIndex*NUM_DIMENSIONS + i];
            sum += abs(tmp)+1e-30;
        }
    #endif
    #if DISTANCE_MEASURE == 2 // Maximum distance 
        #pragma unroll 1 // Prevent compiler from unrolling this loop, eats up too many registers
        for(int i = 0; i < NUM_DIMENSIONS; i++){
            tmp = abs(events[i*NUM_EVENTS + eventIndex] - center[i]);
            //tmp = abs(events[eventIndex*NUM_DIMENSIONS + i] - clusters[clusterIndex*NUM_DIMENSIONS + i]);
            if(tmp > sum)
                sum = tmp+1e-30;
        }
    #endif
	return sum;
}

__device__ float CalculateQII(const float* events, int cluster_index_I, float* EI, float* numMem, float* distanceMatrix){
	EI[threadIdx.x] = 0;
	numMem[threadIdx.x] = 0;
	
	for(int i = threadIdx.x; i < NUM_EVENTS; i+=Q_THREADS){
        float distance = distanceMatrix[cluster_index_I*NUM_EVENTS+i];
		float memVal = MembershipValueDist(cluster_index_I, i, distance, distanceMatrix);
		
		if(memVal > MEMBER_THRESH){
			EI[threadIdx.x] += memVal*memVal * distance*distance;
			numMem[threadIdx.x]++;
		}
	}
	
	__syncthreads();
	
	if(threadIdx.x == 0){
		for(int i = 1; i < Q_THREADS; i++){
			EI[0] += EI[i];
			numMem[0] += numMem[i];
		}
	}
	__syncthreads();

	return ((((float)K1) * numMem[0]) - (((float)K2) * EI[0]) - (((float)K3) * NUM_DIMENSIONS));
}

__device__ float CalculateQIJ(const float* events, int cluster_index_I, int cluster_index_J, float * EI, float * EJ, float *numMem, float* distanceMatrix){
	EI[threadIdx.x] = 0;
	EJ[threadIdx.x] = 0;
	numMem[threadIdx.x] = 0;
	
	for(int i = threadIdx.x; i < NUM_EVENTS; i+=Q_THREADS){
            float distance = distanceMatrix[cluster_index_I*NUM_EVENTS+i];
			float memValI = MembershipValueDist(cluster_index_I, i, distance, distanceMatrix);
		
			if(memValI > MEMBER_THRESH){
				EI[threadIdx.x] += memValI*memValI * distance*distance;
			}
			
            distance = distanceMatrix[cluster_index_J*NUM_EVENTS+i];
			float memValJ = MembershipValueDist(cluster_index_J, i, distance, distanceMatrix);
			if(memValJ > MEMBER_THRESH){
				EJ[threadIdx.x] += memValJ*memValJ * distance*distance;
			}
			if(memValI > MEMBER_THRESH && memValJ > MEMBER_THRESH){
				numMem[threadIdx.x]++;
			}
	
	}
	__syncthreads();

	if(threadIdx.x == 0){
		for(int i = 1; i < Q_THREADS; i++){
			EI[0] += EI[i];
			EJ[0] += EJ[i];
			numMem[0] += numMem[i];
		}
	}

	__syncthreads();
	float EB = (EI[0] > EJ[0]) ? EI[0] : EJ[0];
	return ((-1*((float)K1)*numMem[0]) + ((float)K2)*EB);
}

__global__ void CalculateQMatrixGPUUpgrade(const float* events, const float* clusters, float* matrix, float* distanceMatrix){
	__shared__ float EI[Q_THREADS];
	__shared__ float EJ[Q_THREADS];
	__shared__ float numMem[Q_THREADS];
	
	if(blockIdx.x == blockIdx.y){
		matrix[blockIdx.x*NUM_CLUSTERS + blockIdx.y ] = CalculateQII(events, blockIdx.x, EI, numMem, distanceMatrix);
	}
	else{
		matrix[blockIdx.x*NUM_CLUSTERS + blockIdx.y] = CalculateQIJ(events, blockIdx.x, blockIdx.y, EI, EJ, numMem, distanceMatrix);
	}	
}
