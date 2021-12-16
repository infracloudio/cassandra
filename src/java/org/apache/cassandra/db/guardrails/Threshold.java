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

package org.apache.cassandra.db.guardrails;

import java.util.function.Function;
import javax.annotation.Nullable;

import org.apache.cassandra.service.ClientState;

/**
 * A guardrail based on numeric threshold(s).
 *
 * <p>A {@link Threshold} guardrail defines (up to) 2 thresholds, one at which a warning is issued, and a higher one
 * at which the operation is aborted with an exception. Only one of those thresholds can be activated if desired.
 *
 * <p>This guardrail only handles guarding positive values.
 */
public class Threshold extends Guardrail
{
    private final Function<ClientState, Config> configProvider;
    private final ErrorMessageProvider messageProvider;

    /**
     * Creates a new threshold guardrail.
     *
     * @param configProvider  a {@link ClientState}-based provider of {@link Config}s.
     * @param messageProvider a function to generate the warning or error message if the guardrail is triggered
     */
    public Threshold(Function<ClientState, Config> configProvider, ErrorMessageProvider messageProvider)
    {
        this.configProvider = configProvider;
        this.messageProvider = messageProvider;
    }

    private String errMsg(boolean isWarning, String what, long value, long thresholdValue)
    {
        return messageProvider.createMessage(isWarning,
                                             what,
                                             value,
                                             thresholdValue);
    }

    private long abortValue(Config config)
    {
        long abortValue = config.getAbortThreshold();
        return abortValue < 0 ? Long.MAX_VALUE : abortValue;
    }

    private long warnValue(Config config)
    {
        long warnValue = config.getWarnThreshold();
        return warnValue < 0 ? Long.MAX_VALUE : warnValue;
    }

    @Override
    public boolean enabled(@Nullable ClientState state)
    {
        if (!super.enabled(state))
            return false;

        Config config = configProvider.apply(state);
        return config.getAbortThreshold() >= 0 || config.getWarnThreshold() >= 0;
    }

    /**
     * Apply the guardrail to the provided value, warning or aborting if appropriate.
     *
     * @param value The value to check.
     * @param what  A string describing what {@code value} is a value of. This is used in the error message if the
     *              guardrail is triggered. For instance, say the guardrail guards the size of column values, then this
     *              argument must describe which column of which row is triggering the guardrail for convenience.
     * @param state The client state, used to skip the check if the query is internal or is done by a superuser.
     *              A {@code null} value means that the check should be done regardless of the query.
     */
    public void guard(long value, String what, @Nullable ClientState state)
    {
        if (!enabled(state))
            return;

        Config config = configProvider.apply(state);

        long abortValue = abortValue(config);
        if (value > abortValue)
        {
            triggerAbort(value, abortValue, what);
            return;
        }

        long warnValue = warnValue(config);
        if (value > warnValue)
            triggerWarn(value, warnValue, what);
    }

    private void triggerAbort(long value, long abortValue, String what)
    {
        abort(errMsg(false, what, value, abortValue));
    }

    private void triggerWarn(long value, long warnValue, String what)
    {
        warn(errMsg(true, what, value, warnValue));
    }

    /**
     * A function used to build the error message of a triggered {@link Threshold} guardrail.
     */
    interface ErrorMessageProvider
    {
        /**
         * Called when the guardrail is triggered to build the corresponding error message.
         *
         * @param isWarning Whether the trigger is a warning one; otherwise it is an abort one.
         * @param what      A string, provided by the call to the {@link #guard} method, describing what the guardrail
         *                  has been applied to (and that has triggered it).
         * @param value     The value that triggered the guardrail (as a string).
         * @param threshold The threshold that was passed to trigger the guardrail (as a string).
         */
        String createMessage(boolean isWarning, String what, long value, long threshold);
    }

    /**
     * Configuration class containing the thresholds to be used to check if the guarded value should trigger a warning
     * or abort the operation.
     */
    public interface Config
    {
        /**
         * @return The threshold to warn when the guarded value exceeds it. A negative value means disabled.
         */
        public long getWarnThreshold();

        /**
         * @return The threshold to abort the operation when the guarded value exceeds it. A negative value means disabled.
         */
        public long getAbortThreshold();
    }
}