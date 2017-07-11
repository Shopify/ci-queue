import os
import glob
from setuptools import setup

SCRIPTS_PATH = 'ciqueue/redis'


def get_lua_scripts():
    if not os.path.exists(SCRIPTS_PATH):
        os.makedirs(SCRIPTS_PATH)

    paths = []

    for path in glob.glob(os.path.join(
            os.path.dirname(__file__), '../redis/*.lua')):
        filename = os.path.basename(path)

        destination_path = os.path.join(SCRIPTS_PATH, filename)
        with open(destination_path, 'w+') as lua_file:
            lua_file.write("-- AUTOGENERATED FILE DO NOT EDIT DIRECTLY\n")
            lua_file.write(open(path).read())
        paths.append(destination_path)

    return paths


setup(
    name='ciqueue',
    version='0.1',
    packages=['ciqueue'],
    install_requires=['redis', 'tblib', 'uritools'],
    package_data={'': get_lua_scripts()},
    include_package_data=True,
)
