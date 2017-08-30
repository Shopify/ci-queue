i = 0


def test_flakey():
    global i
    i += 1
    if i % 2 == 1:
        assert False
