"""Convert Silero VAD v6 ONNX model to Core ML (.mlpackage).

The Silero VAD v6 model has:
  Inputs:  input (batch, 576), h (1,1,128), c (1,1,128)
  Outputs: output (batch, 1), hn (1,1,128), cn (1,1,128)

The 576 = 512 (num_samples) + 64 (context_size_samples).

For Core ML conversion we use a fixed batch size of 1 per inference call,
matching the sequential LSTM state pass-through pattern.

Usage: python scripts/convert_vad_to_coreml.py
"""
import os
import numpy as np
import coremltools as ct
import onnxruntime as ort

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ONNX_PATH = os.path.join(SCRIPT_DIR, '../../faster-whisper/faster_whisper/assets/silero_vad_v6.onnx')
OUTPUT_DIR = os.path.join(SCRIPT_DIR, '../models')
os.makedirs(OUTPUT_DIR, exist_ok=True)

print(f"Converting: {ONNX_PATH}")

# Verify ONNX model
sess = ort.InferenceSession(ONNX_PATH, providers=["CPUExecutionProvider"])
for inp in sess.get_inputs():
    print(f"  Input:  {inp.name} shape={inp.shape} type={inp.type}")
for out in sess.get_outputs():
    print(f"  Output: {out.name} shape={out.shape} type={out.type}")

# Convert to Core ML
# The model accepts variable batch but we use batch=1 for sequential processing
# Note: the ONNX model output names differ from what we expected.
# Actual outputs: speech_probs, hn, cn
model = ct.convert(
    ONNX_PATH,
    source="unified",
    inputs=[
        ct.TensorType(name="input", shape=(1, 576), dtype=np.float32),
        ct.TensorType(name="h", shape=(1, 1, 128), dtype=np.float32),
        ct.TensorType(name="c", shape=(1, 1, 128), dtype=np.float32),
    ],
    minimum_deployment_target=ct.target.macOS14,
    compute_precision=ct.precision.FLOAT32,
)

output_path = os.path.join(OUTPUT_DIR, 'silero_vad_v6.mlpackage')
model.save(output_path)
print(f"Saved: {output_path}")

# Verify: run both models on test input and compare
test_input = np.random.randn(1, 576).astype(np.float32) * 0.1
h0 = np.zeros((1, 1, 128), dtype=np.float32)
c0 = np.zeros((1, 1, 128), dtype=np.float32)

onnx_out, onnx_h, onnx_c = sess.run(None, {"input": test_input, "h": h0, "c": c0})

import coremltools
cml = coremltools.models.MLModel(output_path)
# Discover output names
print(f"\nCore ML outputs: {[o.name for o in cml.output_description]}")
cml_result = cml.predict({"input": test_input, "h": h0, "c": c0})
# Use actual output names (may be speech_probs, hn, cn)
out_names = list(cml_result.keys())
print(f"  Result keys: {out_names}")
cml_out = np.array(cml_result[out_names[0]])
cml_h = np.array(cml_result[out_names[1]])
cml_c = np.array(cml_result[out_names[2]])

print(f"\nVerification:")
print(f"  output max diff: {np.max(np.abs(onnx_out - cml_out)):.8f}")
print(f"  h max diff:      {np.max(np.abs(onnx_h - cml_h)):.8f}")
print(f"  c max diff:      {np.max(np.abs(onnx_c - cml_c)):.8f}")

if np.max(np.abs(onnx_out - cml_out)) < 1e-4:
    print("  PASS: Core ML output matches ONNX within 1e-4")
else:
    print("  FAIL: Output mismatch!")
