import Foundation
import Metal

let NUM_AGENTS = 10000

func main() {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("Metal is not supported on this device")
        return
    }
    
    print("=== Zigworld Metal Compute Prototype ===")
    print("Hardware Detected: \(device.name)")
    
    let shaderPath = "src/agents.metal"
    let fileManager = FileManager.default
    var actualPath = shaderPath
    
    if !fileManager.fileExists(atPath: actualPath) {
        actualPath = "../src/agents.metal"
        if !fileManager.fileExists(atPath: actualPath) {
            print("Could not locate src/agents.metal. Please run from the root of the repository.")
            return
        }
    }
    
    guard let source = try? String(contentsOfFile: actualPath) else {
        print("Could not read shader source.")
        return
    }
    
    do {
        print("Compiling Metal Library dynamically...")
        let library = try device.makeLibrary(source: source, options: nil)
        guard let kernelFunction = library.makeFunction(name: "updateAgents") else {
            print("Could not find kernel function 'updateAgents'")
            return
        }
        
        let pipelineState = try device.makeComputePipelineState(function: kernelFunction)
        guard let commandQueue = device.makeCommandQueue() else { return }
        
        // Initialize host memory arrays
        var x_pos = [Float](repeating: 0.0, count: NUM_AGENTS)
        var y_pos = [Float](repeating: 50.0, count: NUM_AGENTS) // All start perfectly at the equator (Y=50)
        var vuln = [Float](repeating: 0.0, count: NUM_AGENTS)
        
        for i in 0..<NUM_AGENTS {
            x_pos[i] = Float(i % 100)
            vuln[i] = Float(i) / Float(NUM_AGENTS)
        }
        
        // Push memory down to the GPU VRAM
        let xBuffer = device.makeBuffer(bytes: &x_pos, length: MemoryLayout<Float>.stride * NUM_AGENTS, options: .storageModeShared)
        let yBuffer = device.makeBuffer(bytes: &y_pos, length: MemoryLayout<Float>.stride * NUM_AGENTS, options: .storageModeShared)
        let vulnBuffer = device.makeBuffer(bytes: &vuln, length: MemoryLayout<Float>.stride * NUM_AGENTS, options: .storageModeShared)
        
        var tempAnomaly: Float = 1.84
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // GPU Command Dispatch
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
        
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setBuffer(xBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(yBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(vulnBuffer, offset: 0, index: 2)
        computeEncoder.setBytes(&tempAnomaly, length: MemoryLayout<Float>.stride, index: 3)
        
        let gridSize = MTLSizeMake(NUM_AGENTS, 1, 1)
        var threadGroupSize = pipelineState.maxTotalThreadsPerThreadgroup
        if threadGroupSize > NUM_AGENTS { threadGroupSize = NUM_AGENTS }
        let threadgroupSize = MTLSizeMake(threadGroupSize, 1, 1)
        
        computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        
        // Read the memory back into CPU space
        let resultY = yBuffer!.contents().bindMemory(to: Float.self, capacity: NUM_AGENTS)
        let resultX = xBuffer!.contents().bindMemory(to: Float.self, capacity: NUM_AGENTS)
        
        print("\n✅ GPU Compute Successful!")
        print("Processed 10,000 spatial agents simultaneously in \(String(format: "%.6f", elapsed)) seconds.")
        print("--- Simulation Metrics ---")
        print("Agents started directly on Equator (Y=50) with Temp Anomaly +1.84C")
        print("Agent 0 (Vulnerability 0.0): Drifted to X=\(String(format: "%.2f", resultX[0])), Migrated to Y=\(String(format: "%.2f", resultY[0]))")
        print("Agent 5000 (Vulnerability 0.5): Drifted to X=\(String(format: "%.2f", resultX[5000])), Migrated to Y=\(String(format: "%.2f", resultY[5000]))")
        print("Agent 9999 (Vulnerability 1.0): Drifted to X=\(String(format: "%.2f", resultX[9999])), Migrated to Y=\(String(format: "%.2f", resultY[9999]))")
        
    } catch {
        print("Metal compilation/execution error: \(error)")
    }
}

main()
