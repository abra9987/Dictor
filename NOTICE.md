# Notices

Dictor is a personal fork. The upstream attribution below is preserved because
the MIT license requires it. The same origin is stated in the README, so that a
reader sees it without opening this file.

# Attribution

Dictor descends from [Parakey](https://github.com/rcourtman/parakey),
originally created by Richard Courtman and distributed under the MIT License.

The original copyright notice and license are preserved in `LICENSE`.

Everything that makes Dictor its own product — the interface, the design
system, service management, history, statistics and the dictation workflow —
is the work of this project.

The speech model is [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra)
by Moondream, a post-training of NVIDIA's
[Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3). Both
are licensed under CC BY 4.0. Dictor downloads the Core ML conversion published
by FluidInference and does not modify the weights. The model is loaded through
[FluidAudio](https://github.com/FluidInference/FluidAudio). Third-party Swift
package licenses remain available through their respective upstream projects.
