# CompressIt
CompressIt is a high performance binary serializer written in pure Luau for Roblox. It utilizes a professional three-phase pipeline consisting of Probe, Encode, and Decode to plan and execute data packing. By using Varints, Quaternions, and string interning, it significantly reduces buffer sizes and network latency while maintaining peak execution.
