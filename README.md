jvm-service-scripts
===================

A set of scripts written to start services on a JVM in a somewhat flexible way.

The script was written to simplify a heterogeneous collections of service shell scripts that ended up being hardcoded in all the repositories along with JVM settings.

Some elements are a bit specific, for example they somewhat assume you could be using Apache log4j, YourKit Profiler under 64 bit linux and NewRelic but they can be easily removed or customized.


The scripts relies also on the ability to set system wide JVM settings in order to be consistent across your servers. So it would read properties located in /opt/service/java/jvm.conf (Typically installed via Puppet or Chef across your servers)

This can be used for example to:

- Avoid discrepancies in settings such as the bug I reported in May 2011 against JDK 6 where even if your OS is configured as GMT, the timezone id selected could be different across servers. http://bugs.sun.com/bugdatabase/view_bug.do?bug_id=7046662. So using -Duser.timezone=GMT is preferred to guard against code that may use default date formatting.
- Set a script to run in case of OutOfMemoryError. On its simplest case: -XX:OnOutOfMemoryError="kill -9 %p;"
- Set lower default timeout for URL-based HTTP client via -Dsun.net.client.defaultConnectTimeout=5000 -Dsun.net.client.defaultReadTimeout=5000 
- Always start the JVM with -showversion to validate you're really running with what you're expecting

See the file bin/jvm.conf.default for more examples.