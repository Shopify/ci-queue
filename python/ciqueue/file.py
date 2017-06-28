from ciqueue.static import Static


class File(Static):
    def __init__(self, path, **kwargs):
        with open(path) as f:
            super(File, self).__init__(f.read().splitlines(), **kwargs)
