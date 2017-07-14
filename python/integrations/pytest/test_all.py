import pytest


class Unserializable(Exception):
    __module__ = 'builtins'


def success(self, test_method):
    pass


def fail(self, test_method):
    assert False


def t_success(self):
    pass


def t_fail(self):
    assert False


def t_ufail(self):
    raise Unserializable()


@pytest.mark.skip("message")
def t_mskip(self):
    pass


def t_mfail(self):
    pytest.fail()


@pytest.mark.xfail
def t_mxfail(self):
    pass


def methods(setup_method, test_method, teardown_method):
    return {'setup_method': setup_method,
            'test_method': test_method,
            'teardown_method': teardown_method}


TestHappy = type('TestHappy', (),
                 methods(success, t_success, success))
TestSadSetup = type('TestSadSetup', (),
                    methods(fail, t_success, success))
TestSadTest = type('TestSadTest', (),
                   methods(success, t_fail, success))
TestSadTeardown = type('TestSadTeardown', (),
                       methods(success, t_success, fail))
TestSadSetupTest = type('TestSadSetupTest', (),
                        methods(fail, t_fail, success))
TestSadSetupTeardown = type('TestSadSetupTeardown', (),
                            methods(fail, t_success, fail))
TestSadTestTeardown = type('TestSadTestTeardown', (),
                           methods(success, t_fail, fail))
TestSad = type('TestSad', (),
               methods(fail, t_fail, fail))
TestSkip = type('TestSkip', (),
                methods(success, t_mskip, success))
TestXFail = type('TestXFail', (),
                 methods(success, t_mxfail, success))
TestFail = type('TestFail', (),
                methods(success, t_mfail, success))
TestUnserializableException = type('TestUnserializableException', (),
                                   methods(success, t_ufail, success))
