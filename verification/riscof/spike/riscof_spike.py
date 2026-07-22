import os
import logging
import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

class spike(pluginTemplate):
    __model__ = "spike"
    __version__ = "1.1.1"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get('config')
        if config is None:
            logger.error("Config node for spike missing.")
            raise SystemExit(1)
        self.num_jobs = str(config['jobs'] if 'jobs' in config else 1)
        self.pluginpath = os.path.abspath(config['pluginpath'])
        self.ref_exe = os.path.join(config['PATH'] if 'PATH' in config else "", "spike")
        self.isa_spec = os.path.abspath(config['ispec'])
        self.platform_spec = os.path.abspath(config['pspec'])

    def initialise(self, suite, work_dir, archtest_env):
        self.suite = suite
        self.work_dir = work_dir
        self.objdump_cmd = 'riscv64-unknown-elf-objdump -D {0} > {1};'
        # The REF must run the SAME binary environment as the DUT: link
        # script and model_test.h come from the fluxcore plugin's env.
        dut_env = os.path.join(self.pluginpath, '..', 'fluxcore', 'env')
        self.compile_cmd = ('riscv64-unknown-elf-gcc -march={0} -mabi=ilp32 '
            '-static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles '
            '-g -T ' + dut_env + '/link.ld '
            '-I ' + dut_env + '/ '
            '-I ' + archtest_env + ' {1} -o {2} {3}')

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)['hart0']
        self.xlen = ('64' if 64 in ispec['supported_xlen'] else '32')
        self.isa = 'rv' + self.xlen
        for ext in ['I', 'M', 'A', 'F', 'D', 'C']:
            if ext in ispec['ISA']:
                self.isa += ext.lower()
        self.isa += '_zicsr_zifencei'
        self.mabi = 'ilp32' if self.xlen == '32' else 'lp64'

    def runTests(self, testList):
        for testname in testList:
            testentry = testList[testname]
            test = testentry['test_path']
            test_dir = testentry['work_dir']
            os.makedirs(test_dir, exist_ok=True)
            elf = 'ref.elf'
            sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")
            compile_macros = ' -D' + " -D".join(testentry['macros'])
            marchstr = testentry['isa'].lower()
            if 'zicsr' not in marchstr:    marchstr += '_zicsr'
            if 'zifencei' not in marchstr: marchstr += '_zifencei'
            cmd = self.compile_cmd.format(marchstr, test, elf, compile_macros)
            simcmd = (self.ref_exe + ' --isa={0} +signature={1} '
                      '+signature-granularity=4 {2}').format(self.isa, sig_file, elf)
            execute = ('export PATH=/home/lnx-141209/Desktop/FluxCore/build/dtc:$PATH; '
                       'cd {0}; {1}; {2};').format(test_dir, cmd, simcmd)
            logger.debug('Executing on Spike ' + execute)
            utils.shellCommand(execute).run()
