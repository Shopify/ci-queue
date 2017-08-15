from ciqueue import static


class File(static.Static):

    def __init__(self, path, **kwargs):
        with open(path) as test_file:
            super(File, self).__init__(test_file.read().splitlines(), **kwargs)
