/*
 * WangXun 10 Gigabit PCI Express Linux driver
 * Copyright (c) 2015 - 2017 Beijing WangXun Technology Co., Ltd.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms and conditions of the GNU General Public License,
 * version 2, as published by the Free Software Foundation.
 *
 * This program is distributed in the hope it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 *
 * The full GNU General Public License is included in this distribution in
 * the file called "COPYING".
 *
 * based on ixgbe_sysfs.c, Copyright(c) 1999 - 2017 Intel Corporation.
 * Contact Information:
 * Linux NICS <linux.nics@intel.com>
 * e1000-devel Mailing List <e1000-devel@lists.sourceforge.net>
 * Intel Corporation, 5200 N.E. Elam Young Parkway, Hillsboro, OR 97124-6497
 */


#include "txgbe.h"
#include "txgbe_hw.h"
#include "txgbe_type.h"

#ifdef TXGBE_SYSFS

#include <linux/module.h>
#include <linux/types.h>
#include <linux/sysfs.h>
#include <linux/kobject.h>
#include <linux/device.h>
#include <linux/netdevice.h>
#include <linux/time.h>
#ifdef TXGBE_HWMON
#include <linux/hwmon.h>
#endif

#ifdef TXGBE_HWMON
#ifdef HAVE_HWMON_DEVICE_REGISTER_WITH_INFO
static int txgbe_hwmon_read(struct device *dev,
			    enum hwmon_sensor_types type,
			    u32 attr, int channel, long *val)
{
	struct txgbe_adapter *adapter = dev_get_drvdata(dev);
	unsigned int value;

	if (!adapter)
		return -EIO;

	if (type != hwmon_temp || channel != 0 || attr != hwmon_temp_input)
		return -EOPNOTSUPP;

	/* reset the temp field */
	TCALL(&adapter->hw, mac.ops.get_thermal_sensor_data);

	value = adapter->hw.mac.thermal_sensor_data.sensor.temp;

	/* report millidegree */
	*val = value * 1000;

	return 0;
}

static umode_t txgbe_hwmon_is_visible(const void *data __always_unused,
				      enum hwmon_sensor_types type,
				      u32 attr, int channel)
{
	if (type == hwmon_temp && channel == 0 && attr == hwmon_temp_input)
		return 0444;

	return 0;
}

static const struct hwmon_ops txgbe_hwmon_ops = {
	.is_visible = txgbe_hwmon_is_visible,
	.read = txgbe_hwmon_read,
};

static const struct hwmon_channel_info *txgbe_hwmon_info[] = {
	HWMON_CHANNEL_INFO(temp, HWMON_T_INPUT),
	NULL
};

static const struct hwmon_chip_info txgbe_hwmon_chip_info = {
	.ops = &txgbe_hwmon_ops,
	.info = txgbe_hwmon_info,
};
#endif /* HAVE_HWMON_DEVICE_REGISTER_WITH_INFO */

static struct device *txgbe_hwmon_device_register(struct txgbe_adapter *adapter)
{
#if defined(HAVE_HWMON_DEVICE_REGISTER_WITH_INFO) || \
    defined(HAVE_HWMON_DEVICE_REGISTER_WITH_GROUPS)
	struct device *hwmon_dev;
#endif

#ifdef HAVE_HWMON_DEVICE_REGISTER_WITH_INFO
	hwmon_dev = hwmon_device_register_with_info(pci_dev_to_dev(adapter->pdev),
						    "txgbe", adapter,
						    &txgbe_hwmon_chip_info,
						    NULL);
	if (!IS_ERR(hwmon_dev))
		return hwmon_dev;
#endif

#ifdef HAVE_HWMON_DEVICE_REGISTER_WITH_GROUPS
	hwmon_dev = hwmon_device_register_with_groups(pci_dev_to_dev(adapter->pdev),
						      "txgbe", NULL, NULL);
	if (!IS_ERR(hwmon_dev))
		return hwmon_dev;
#endif

	return hwmon_device_register(pci_dev_to_dev(adapter->pdev));
}

/* hwmon callback functions */
static ssize_t txgbe_hwmon_show_temp(struct device __always_unused *dev,
				     struct device_attribute *attr,
				     char *buf)
{
	struct hwmon_attr *txgbe_attr = container_of(attr, struct hwmon_attr,
						     dev_attr);
	unsigned int value;

	/* reset the temp field */
	TCALL(txgbe_attr->hw, mac.ops.get_thermal_sensor_data);

	value = txgbe_attr->sensor->temp;

	/* display millidegree */
	value *= 1000;

	return sprintf(buf, "%u\n", value);
}

static ssize_t txgbe_hwmon_show_alarmthresh(struct device __always_unused *dev,
				     struct device_attribute *attr,
				     char *buf)
{
	struct hwmon_attr *txgbe_attr = container_of(attr, struct hwmon_attr,
						     dev_attr);
	unsigned int value = txgbe_attr->sensor->alarm_thresh;

	/* display millidegree */
	value *= 1000;

	return sprintf(buf, "%u\n", value);
}

static ssize_t txgbe_hwmon_show_dalarmthresh(struct device __always_unused *dev,
				     struct device_attribute *attr,
				     char *buf)
{
	struct hwmon_attr *txgbe_attr = container_of(attr, struct hwmon_attr,
						     dev_attr);
	unsigned int value = txgbe_attr->sensor->dalarm_thresh;

	/* display millidegree */
	value *= 1000;

	return sprintf(buf, "%u\n", value);
}

/**
 * txgbe_add_hwmon_attr - Create hwmon attr table for a hwmon sysfs file.
 * @adapter: pointer to the adapter structure
 * @type: type of sensor data to display
 *
 * For each file we want in hwmon's sysfs interface we need a device_attribute
 * This is included in our hwmon_attr struct that contains the references to
 * the data structures we need to get the data to display.
 */
static int txgbe_add_hwmon_attr(struct txgbe_adapter *adapter, int type)
{
	int rc;
	unsigned int n_attr;
	struct hwmon_attr *txgbe_attr;

	n_attr = adapter->txgbe_hwmon_buff.n_hwmon;
	txgbe_attr = &adapter->txgbe_hwmon_buff.hwmon_list[n_attr];

	switch (type) {
	case TXGBE_HWMON_TYPE_TEMP:
		txgbe_attr->dev_attr.show = txgbe_hwmon_show_temp;
		snprintf(txgbe_attr->name, sizeof(txgbe_attr->name),
			 "temp%u_input", 0);
		break;
	case TXGBE_HWMON_TYPE_ALARMTHRESH:
		txgbe_attr->dev_attr.show = txgbe_hwmon_show_alarmthresh;
		snprintf(txgbe_attr->name, sizeof(txgbe_attr->name),
			 "temp%u_alarmthresh", 0);
		break;
	case TXGBE_HWMON_TYPE_DALARMTHRESH:
		txgbe_attr->dev_attr.show = txgbe_hwmon_show_dalarmthresh;
		snprintf(txgbe_attr->name, sizeof(txgbe_attr->name),
			 "temp%u_dalarmthresh", 0);
		break;
	default:
		rc = -EPERM;
		return rc;
	}

	/* These always the same regardless of type */
	txgbe_attr->sensor =
		&adapter->hw.mac.thermal_sensor_data.sensor;
	txgbe_attr->hw = &adapter->hw;
	txgbe_attr->dev_attr.store = NULL;
	txgbe_attr->dev_attr.attr.mode = S_IRUGO;
	txgbe_attr->dev_attr.attr.name = txgbe_attr->name;

	/* Avoid EEXIST on stale entries after partial init/unload paths. */
	device_remove_file(pci_dev_to_dev(adapter->pdev),
			   &txgbe_attr->dev_attr);

	rc = device_create_file(pci_dev_to_dev(adapter->pdev),
				&txgbe_attr->dev_attr);
	if (rc)
		e_dev_warn("hwmon sysfs create failed: %s rc=%d\n",
			   txgbe_attr->name, rc);

	if (rc == 0)
		++adapter->txgbe_hwmon_buff.n_hwmon;

	return rc;
}
#endif /* TXGBE_HWMON */

static void txgbe_sysfs_del_adapter(
				struct txgbe_adapter __maybe_unused *adapter)
{
#ifdef TXGBE_HWMON
	int i;

	if (adapter == NULL)
		return;

	if (adapter->txgbe_hwmon_buff.hwmon_list) {
		for (i = 0; i < adapter->txgbe_hwmon_buff.n_hwmon; i++) {
			device_remove_file(pci_dev_to_dev(adapter->pdev),
				   &adapter->txgbe_hwmon_buff.hwmon_list[i].dev_attr);
		}

		kfree(adapter->txgbe_hwmon_buff.hwmon_list);
		adapter->txgbe_hwmon_buff.hwmon_list = NULL;
	}

	if (!IS_ERR_OR_NULL(adapter->txgbe_hwmon_buff.device))
		hwmon_device_unregister(adapter->txgbe_hwmon_buff.device);
	adapter->txgbe_hwmon_buff.device = NULL;

	adapter->txgbe_hwmon_buff.n_hwmon = 0;
#endif /* TXGBE_HWMON */
}

/* called from txgbe_main.c */
void txgbe_sysfs_exit(struct txgbe_adapter *adapter)
{
	txgbe_sysfs_del_adapter(adapter);
}

/* called from txgbe_main.c */
int txgbe_sysfs_init(struct txgbe_adapter *adapter)
{
	int rc = 0;
#ifdef TXGBE_HWMON
	struct hwmon_buff *txgbe_hwmon = &adapter->txgbe_hwmon_buff;
	int n_attrs;

#endif /* TXGBE_HWMON */
	if (adapter == NULL)
		goto err;

#ifdef TXGBE_HWMON

	/* Don't create thermal hwmon interface if no sensors present */
	if (TCALL(&adapter->hw, mac.ops.init_thermal_sensor_thresh))
		goto no_thermal;

	/*
	 * Allocation space for max attributs
	 * max num sensors * values (temp, alamthresh, dalarmthresh)
	 */
	n_attrs = 3;
	txgbe_hwmon->device = NULL;
	txgbe_hwmon->n_hwmon = 0;
	txgbe_hwmon->hwmon_list = kcalloc(n_attrs, sizeof(struct hwmon_attr),
					  GFP_KERNEL);
	if (!txgbe_hwmon->hwmon_list) {
		rc = -ENOMEM;
		goto err;
	}

	txgbe_hwmon->device = txgbe_hwmon_device_register(adapter);
	if (IS_ERR(txgbe_hwmon->device)) {
		rc = PTR_ERR(txgbe_hwmon->device);
		txgbe_hwmon->device = NULL;
		goto err;
	}


	/* Bail if any hwmon attr struct fails to initialize */
	rc = txgbe_add_hwmon_attr(adapter, TXGBE_HWMON_TYPE_TEMP);
	rc |= txgbe_add_hwmon_attr(adapter, TXGBE_HWMON_TYPE_ALARMTHRESH);
	rc |= txgbe_add_hwmon_attr(adapter, TXGBE_HWMON_TYPE_DALARMTHRESH);
	if (rc)
		goto err;

no_thermal:
#endif /* TXGBE_HWMON */
	goto exit;

err:
	txgbe_sysfs_del_adapter(adapter);
exit:
	return rc;
}
#endif /* TXGBE_SYSFS */
