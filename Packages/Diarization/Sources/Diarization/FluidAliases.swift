// This file imports FluidAudio only. FluidAudio's frame-based `Diarizer` protocol has the same name as AppCore's
// `Diarizer`, and FluidAudio also contains a type named `FluidAudio`, so it cannot be module-qualified elsewhere.
import FluidAudio

/// FluidAudio's frame-based streaming diarizer protocol (LS-EEND, Sortformer).
typealias FluidFrameDiarizer = Diarizer
