def can_build(env, platform):
    return platform == "visionos"


def configure(env):
    pass


def get_doc_classes():
    return [
        "SharePlayMultiplayerPeer",
    ]


def get_doc_path():
    return "doc_classes"
