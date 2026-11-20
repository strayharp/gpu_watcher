import Foundation

/// Canned probe output in the exact format the servers produce. Used by `--demo` / `--render`
/// to exercise the parser and the UI without touching any real host.
enum Demo {
    static let hosts = ["lab-gpu-1", "lab-gpu-2", "lab-gpu-3", "lab-gpu-4"]

    @MainActor
    static func states() -> [String: HostState] {
        var out: [String: HostState] = [:]
        out["lab-gpu-1"] = HostState(snapshot: ProbeParser.parse(host1), updated: Date())
        out["lab-gpu-2"] = HostState(snapshot: ProbeParser.parse(host2), updated: Date())
        out["lab-gpu-3"] = HostState(error: .auth("alice@lab-gpu-3: Permission denied (publickey,password)."))
        out["lab-gpu-4"] = HostState(error: .unreachable("ssh: connect to host 192.0.2.44 port 22: Operation timed out"))
        return out
    }

    static let host1 = """
    @@HOST
    lab-gpu-1
    alice
    @@GPU
    0, GPU-8f6a2c1e-0000-0000-0000-000000000000, NVIDIA GeForce RTX 3090, 98, 22145, 24576, 71, 331.52, 74
    1, GPU-8f6a2c1e-0000-0000-0000-000000000001, NVIDIA GeForce RTX 3090, 100, 23410, 24576, 86, 345.10, 91
    2, GPU-8f6a2c1e-0000-0000-0000-000000000002, NVIDIA GeForce RTX 3090, 64, 11872, 24576, 63, 240.77, 55
    3, GPU-8f6a2c1e-0000-0000-0000-000000000003, NVIDIA GeForce RTX 3090, 0, 4, 24576, 34, 21.40, 30
    @@APPS
    GPU-8f6a2c1e-0000-0000-0000-000000000000, 231455, 22136
    GPU-8f6a2c1e-0000-0000-0000-000000000001, 231455, 22136
    GPU-8f6a2c1e-0000-0000-0000-000000000001, 9981, 1266
    GPU-8f6a2c1e-0000-0000-0000-000000000002, 778123, 11864
    @@PMON
    # gpu         pid   type     sm    mem    enc    dec    jpg    ofa     fb   ccpm    command
    # Idx           #    C/G      %      %      %      %      %      %     MB     MB    name
        0     231455     C     97     64      -      -      -      -  22136      0    python
        1     231455     C     93     61      -      -      -      -  22136      0    python
        1       9981     C      6      2      -      -      -      -   1266      0    python3
        2     778123     C     64     31      -      -      -      -  11864      0    python
        3          -     -      -      -      -      -      -      -      -      -    -
    @@PS
        PID USER                             ELAPSED  CPU   RSS ARGS
       9981 bob                                 4210 12.5 2101244 /usr/bin/python3 -m ipykernel_launcher -f /run/user/1002/jupyter/kernel-3f1.json
     231455 alice                             187345  201 9234512 /home/alice/miniconda3/envs/llm/bin/python /home/alice/proj/vit/train.py --config configs/vit_l16.yaml --seed 1 --amp
     778123 carol                              51020 99.0 6120040 python -u tools/finetune.py --model llama-3-8b --lora-r 16 --data sft_v2.jsonl
    @@CWD
    9981\t
    231455\t/home/alice/proj/vit
    778123\t
    @@SYS
    18.42 17.90 16.05 21/1843 3312201
    64
    257642 96311
    @@END
    """

    static let host2 = """
    @@HOST
    lab-gpu-2
    alice
    @@GPU
    0, GPU-1b2c3d4e-0000-0000-0000-000000000000, NVIDIA RTX A6000, 100, 44120, 49140, 79, 289.03, 68
    1, GPU-1b2c3d4e-0000-0000-0000-000000000001, NVIDIA RTX A6000, 0, 12, 49140, 31, [N/A], 30
    @@APPS
    GPU-1b2c3d4e-0000-0000-0000-000000000000, 40117, 44106
    @@PMON
    # gpu        pid  type    sm   mem   enc   dec   command
    # Idx          #   C/G     %     %     %     %   name
        0      40117     C    99    72     -     -   python
        1          -     -     -     -     -     -   -
    @@PS
        PID USER                             ELAPSED  CPU   RSS ARGS
      40117 alice                               5432  104 18233440 python sweep.py --exp ablation_bs --batch-size 256 --lr 3e-4 --wandb
    @@CWD
    40117\t/data/alice/sweeps
    @@SYS
    2.10 2.33 2.40 3/911 88123
    32
    128552 30122
    @@END
    """
}
