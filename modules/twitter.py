import sys
import traceback

from twitterscraper import query_tweets_from_user

from modules.common.pollingservice import PollingService


# https://github.com/taspinar/twitterscraper/tree/master/twitterscraper

class MatrixModule(PollingService):
    def __init__(self, name):
        self.enabled = False

    def __init_enabled(self, name):
        super().__init__(name)
        self.service_name = 'Twitter'

    async def poll_implementation(self, bot, account, roomid, send_messages):
        try:
            tweets = query_tweets_from_user(account, limit=1)
            self.logger.info(f'Polling twitter account {account} - got {len(tweets)} tweets')
            for tweet in tweets:
                if tweet.tweet_id not in self.known_ids:
                    if send_messages:
                        await bot.send_html(bot.get_room_by_id(roomid),
                                            f'<a href="https://twitter.com{tweet.tweet_url}">Twitter {account}</a>: {tweet.text}',
                                            f'Twitter {account}: {tweet.text} - https://twitter.com{tweet.tweet_url}')
                self.known_ids.add(tweet.tweet_id)
        except Exception:
            self.logger.error('Polling twitter account failed:')
            traceback.print_exc(file=sys.stderr)
