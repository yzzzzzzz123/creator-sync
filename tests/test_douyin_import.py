import unittest
from tools.import_douyin_snapshot import own_notes


def node(kind,name='',value=None):
    return {'Type':'ControlType.'+kind,'Name':name,'Value':value}


class OwnProfileTest(unittest.TestCase):
    def snapshot(self):
        return {'Nodes':[
            node('Document','Yu的抖音','https://www.douyin.com/user/self'),
            node('Text','Yu'),node('Text','抖音号：'),node('Text','owner'),
            node('ListItem','置顶旧作品'),
            node('Hyperlink','Yu：旧标题 Tag: 置顶 100 旧标题','https://www.douyin.com/video/12345678901'),
            node('Image','Yu：旧标题'),node('Group','Tag: 置顶'),
            node('ListItem','新作品'),
            node('Hyperlink','Yu：新标题 50 新标题','https://www.douyin.com/video/12345678902'),
            node('Image','Yu：新标题 #钢琴')]}

    def test_caption_is_not_duplicated_and_pinned_is_not_called_latest(self):
        notes=own_notes(self.snapshot(),'owner','Yu')
        self.assertEqual([n['title'] for n in notes],['旧标题','新标题 #钢琴'])
        self.assertEqual([n['pinned'] for n in notes],[True,False])
        self.assertTrue(all(not n['latest_confirmed'] for n in notes))

    def test_wrong_account_or_stale_document_is_rejected(self):
        with self.assertRaises(ValueError):own_notes(self.snapshot(),'another','Yu')
        snapshot=self.snapshot();snapshot['Nodes'][0]['Value']='https://www.douyin.com/user/another'
        with self.assertRaises(ValueError):own_notes(snapshot,'owner','Yu')

    def test_another_authors_card_is_not_imported(self):
        snapshot=self.snapshot();snapshot['Nodes'][-1]['Name']='Other：新标题'
        self.assertEqual(len(own_notes(snapshot,'owner','Yu')),1)
