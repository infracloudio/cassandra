/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.apache.cassandra.security;

import java.security.Provider;
import java.util.Map;
import javax.crypto.Cipher;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.apache.cassandra.exceptions.ConfigurationException;

import static java.lang.String.format;

public abstract class AbstractCryptoProvider
{
    private static final String FAIL_ON_MISSING_PROVIDER_KEY = "fail_on_missing_provider";
    protected final Logger logger = LoggerFactory.getLogger(getClass());

    private final boolean failOnMissingProvider;

    public AbstractCryptoProvider(Map<String, String> properties)
    {
        failOnMissingProvider = properties != null && Boolean.parseBoolean(properties.getOrDefault(FAIL_ON_MISSING_PROVIDER_KEY, "false"));
    }

    /**
     * Returns name of the provider, as returned from {@link Provider#getName()}
     *
     * @return name of the provider
     */
    public abstract String getProviderName();

    /**
     * Returns the name of the class which installs specific provider of name {@link #getProviderName()}.
     *
     * @return name of class of provider
     */
    public abstract String getProviderClassAsString();

    /**
     * Returns a runnable which installs this crypto provider.
     * The installator may throw an exception. The default implementation
     * will not fail the installation unless the parameter {@code fail_on_missing_provider} is {@code true}.
     *
     * @return runnable which installs this provider
     */
    public abstract Runnable installator() throws Exception;

    /**
     * Returns a runnable which executes a health check of this provider to see if it was installed properly.
     * The healthchecker may throw an exception. The default implementation
     * will not fail the installation unless the parameter {@code fail_on_missing_provider} is {@code true}.
     *
     * @return runnable which installs this provider
     */
    public abstract Runnable healthChecker() throws Exception;

    public boolean failOnMissingProvider()
    {
        return failOnMissingProvider;
    }

    public void installProvider()
    {
        String failureMessage = null;
        try
        {
            Class.forName(getProviderClassAsString());

            installator().run();
        }
        catch (ClassNotFoundException ex)
        {
            failureMessage = getProviderClassAsString() + " is not on the class path!";
        }
        catch (Exception e)
        {
            failureMessage = format("The installation of %s was not successful, reason: %s",
                                    getProviderClassAsString(), e.getMessage());
        }

        throwOrWarn(failureMessage);
    }

    public void checkProvider() throws Exception
    {
        String failureMessage = null;
        try
        {
            Class.forName(getProviderClassAsString());

            String currentCryptoProvider = Cipher.getInstance("AES/GCM/NoPadding").getProvider().getName();

            if (getProviderName().equals(currentCryptoProvider))
            {
                healthChecker().run();
                logger.info("{} successfully passed the healthiness check", getProviderName());
            }
            else
            {
                failureMessage = format("%s is not the highest priority provider - %s is used. " +
                                        "The most probable cause is that Cassandra node is not running on the same architecture " +
                                        "the provider library is for. Please place the architecture-specific library " +
                                        "for %s to the classpath and try again. ",
                                        getProviderName(),
                                        currentCryptoProvider,
                                        getProviderClassAsString());
            }
        }
        catch (ClassNotFoundException ex)
        {
            failureMessage = getProviderClassAsString() + " is not on the class path!";
        }
        catch (Exception e)
        {
            failureMessage = format("Exception encountered while asserting the healthiness of %s, reason: %s",
                                    getProviderClassAsString(), e.getMessage());
        }

        throwOrWarn(failureMessage);
    }

    protected void throwOrWarn(String message)
    {
        if (message != null)
            if (failOnMissingProvider())
                throw new ConfigurationException(message);
            else
                logger.warn(message);
    }
}
