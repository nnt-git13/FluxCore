import os
import logging
import riscof.utils as utils
import riscof.constants as constants
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

class fluxcore(pluginTemplate):
    __model__ = "fluxcore"
    __version__ = "2026.07"

    # RTL DUT: each test is compiled against the Harvard link script, turned
    # into one 64 KiB $readmemh image, and run on tb_riscof (fluxcore_top +
    # flat memories) under xsim. The TB dumps the signature region.

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get('config')
        if config is None:
            print("Please enter input file paths in configuration.")
            raise SystemExit(1)
        self.num_jobs = str(config['jobs'] if 'jobs' in config else 1)
        self.pluginpath = os.path.abspath(config['pluginpath'])
        self.isa_spec = os.path.abspath(config['ispec'])
        self.platform_spec = os.path.abspath(config['pspec'])
        self.target_run = ('target_run' not in config or config['target_run'] == '1')
        self.repo = os.path.abspath(os.path.join(self.pluginpath, '..', '..', '..'))

    def initialise(self, suite, work_dir, archtest_env):
        self.work_dir = work_dir
        self.suite_dir = suite
        self.compile_cmd = ('riscv64-unknown-elf-gcc -march={0}_zicsr_zifencei -mabi=ilp32 '
            '-static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles '
            '-g -T ' + self.pluginpath + '/env/link.ld '
            '-I ' + self.pluginpath + '/env/ '
            '-I ' + archtest_env + ' {1} -o {2} {3}')
        # Compile the TB once into a reusable xsim snapshot.
        self.tbdir = os.path.join(self.repo, 'build', 'questa', 'riscof')
        utils.shellCommand(
            'cd {repo} && mkdir -p {tb} && '
            'bash verification/scripts/xsim_run.sh build/questa/riscof '
            'verification/filelists/riscof.f sim/questa/run_unit.do tb_riscof '
            '|| true'.format(repo=self.repo, tb=self.tbdir)).run()
        # xsim_run also RUNS the snapshot once (which dies on missing +hex=);
        # only the compiled snapshot matters here.
        snap = os.path.join(self.tbdir, 'xsim.dir', 'tb_riscof_snap')
        if not os.path.isdir(snap):
            logger.error('tb_riscof snapshot missing: ' + snap)
            raise SystemExit(1)

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)['hart0']
        self.xlen = ('64' if 64 in ispec['supported_xlen'] else '32')

    def runTests(self, testList):
        xsim = os.environ.get('XSIM',
            '/home/lnx-141209/Vivado/2023.1/bin/xsim')
        for testname in testList:
            testentry = testList[testname]
            test = testentry['test_path']
            test_dir = testentry['work_dir']
            elf = os.path.join(test_dir, 'dut.elf')
            sig_file = os.path.join(test_dir, self.name[:-1] + '.signature')
            compile_macros = ' -D' + ' -D'.join(testentry['macros'])
            marchstr = testentry['isa'].lower()

            cmd = self.compile_cmd.format(marchstr, test, elf, compile_macros)
            utils.shellCommand('cd {0}; {1}'.format(test_dir, cmd)).run()

            if not self.target_run:
                continue

            # 64 KiB unified image + signature symbol addresses
            hexf = os.path.join(test_dir, 'image.hex')
            utils.shellCommand(
                'cd {repo} && python3 scripts/elf2hex.py {elf} {hex} '
                '--base 0x80000000 --depth 16384'.format(
                    repo=self.repo, elf=elf, hex=hexf)).run()
            nm = utils.shellCommand(
                'riscv64-unknown-elf-nm {0}'.format(elf)).run(shell=True)
            sigb = sige = None
            with os.popen('riscv64-unknown-elf-nm ' + elf) as f:
                for line in f:
                    parts = line.split()
                    if len(parts) == 3 and parts[2] == 'begin_signature':
                        sigb = parts[0]
                    if len(parts) == 3 and parts[2] == 'end_signature':
                        sige = parts[0]
            if sigb is None or sige is None:
                logger.error('signature symbols missing in ' + elf)
                continue

            # Run the pre-built snapshot from its build dir (xsim resolves
            # the snapshot from CWD/xsim.dir).
            runcmd = ('export LD_LIBRARY_PATH=' + self.repo +
                      '/build/vivado-compat:$LD_LIBRARY_PATH; '
                      'cd {tb} && {xsim} tb_riscof_snap -runall '
                      '-testplusarg hex={hex} -testplusarg sig={sig} '
                      '-testplusarg sigb={sigb} -testplusarg sige={sige} '
                      '> {log} 2>&1').format(
                tb=self.tbdir, xsim=xsim, hex=hexf, sig=sig_file,
                sigb=sigb, sige=sige,
                log=os.path.join(test_dir, 'xsim.log'))
            utils.shellCommand(runcmd).run()
